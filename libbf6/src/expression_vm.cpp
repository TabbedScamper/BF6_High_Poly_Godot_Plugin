#include "expression_vm.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <set>

namespace bf6 { namespace expression {
namespace {

static const uint32_t kParameterValue = 0x9a38f86fu;
static const uint32_t kParameterObject = 0x24637f30u;
static const uint32_t kSink = 0x26730cb8u;
static const uint32_t kTerminator = 0x225e7a5bu;
static const uint32_t kVariableStore = 0x0b201cc7u;

struct Slots {
    explicit Slots(size_t size) : bytes(size), initialized(size), tainted(size) {}
    std::vector<uint8_t> bytes, initialized, tainted;
    std::map<uint32_t, uint32_t> widths;

    Value read(uint32_t offset, uint32_t width) const {
        Value v;
        if (!width || offset > bytes.size() || width > bytes.size() - offset)
            return v;
        v.bytes.assign(bytes.begin() + offset, bytes.begin() + offset + width);
        v.known = true;
        for (uint32_t i = 0; i < width; ++i) {
            const bool byte_known = initialized[offset + i] != 0;
            v.known = v.known && byte_known;
            v.tainted = v.tainted || !byte_known;
            v.tainted = v.tainted || tainted[offset + i] != 0;
        }
        return v;
    }

    bool write(uint32_t offset, uint32_t width, const Value& value) {
        if (!width || offset > bytes.size() || width > bytes.size() - offset ||
            value.bytes.size() < width) return false;
        std::copy(value.bytes.begin(), value.bytes.begin() + width,
                  bytes.begin() + offset);
        std::fill(initialized.begin() + offset, initialized.begin() + offset + width,
                  (uint8_t)(value.known ? 1 : 0));
        std::fill(tainted.begin() + offset, tainted.begin() + offset + width,
                  (uint8_t)(value.tainted ? 1 : 0));
        widths[offset] = width;
        return true;
    }
};

static size_t align16(size_t value) { return (value + 15u) & ~size_t(15u); }

static Value unknown(uint32_t width, bool tainted = true) {
    Value v; v.bytes.resize(width); v.known = false; v.tainted = tainted; return v;
}

static Value materialize(const Graph& graph, const Instance* instance,
                         const Slots& slots, const Operand& operand,
                         uint32_t width)
{
    if (!width) return Value{};
    if (operand.region == 0) {
        if (operand.offset > graph.constant_pool.size() ||
            width > graph.constant_pool.size() - operand.offset)
            return unknown(width);
        Value v;
        v.bytes.assign(graph.constant_pool.begin() + operand.offset,
                       graph.constant_pool.begin() + operand.offset + width);
        v.known = true;
        return v;
    }
    if (operand.region == 1) {
        if (!instance) return unknown(width);
        const size_t base = align16(0x20u +
            (size_t)graph.header.external_bindings * 8u +
            (size_t)graph.header.instance_buffer_count * 4u);
        const size_t at = base + operand.offset;
        if (at > instance->image.size() || width > instance->image.size() - at)
            return unknown(width);
        Value v;
        v.bytes.assign(instance->image.begin() + at,
                       instance->image.begin() + at + width);
        v.known = true;
        // Constructor-owned ranges are deliberately withheld. The data type's
        // exact byte width is not present in the graph, so even the first byte
        // of a declared object is enough to make this read unknown.
        for (const TypedValueGroup& group : graph.instance_values)
            for (uint32_t off : group.offsets)
                if (operand.offset == off) return unknown(width);
        return v;
    }
    if (operand.region == 2) return slots.read(operand.offset, width);
    // All currently measured region-3+ graph operands are inline immediates.
    // Their carried value is the second dword; widths above four need host
    // knowledge and therefore remain unknown.
    if (width > 4) return unknown(width);
    Value v;
    v.bytes.resize(width);
    std::memcpy(v.bytes.data(), &operand.offset, width);
    v.known = true;
    return v;
}

static const Operand* last_slot(const Record& record) {
    for (auto it = record.operands.rbegin(); it != record.operands.rend(); ++it)
        if (it->region == 2) return &*it;
    return nullptr;
}

static uint32_t move_width(const Record& record) {
    if ((record.kind == 0x24 || record.kind == 0x25) &&
        record.has_trailing_dword && record.trailing_dword > 0 &&
        record.trailing_dword <= 4096) return record.trailing_dword;
    if (record.kind == 0x1e) return 1;
    if (record.kind == 0x20 || record.kind == 0x21 || record.kind == 0x22)
        return 4;
    return 0;
}

static void add_unresolved(Evaluation& result, uint32_t key) {
    if (key && std::find(result.unresolved_keys.begin(),
                         result.unresolved_keys.end(), key) ==
               result.unresolved_keys.end())
        result.unresolved_keys.push_back(key);
}

} // namespace

Value Value::from_u32(uint32_t value) {
    Value v; v.bytes.resize(4); std::memcpy(v.bytes.data(), &value, 4);
    v.known = true; return v;
}

Value Value::from_bool(bool value) {
    Value v; v.bytes.push_back(value ? 1u : 0u); v.known = true; return v;
}

uint32_t Value::as_u32() const {
    uint32_t v = 0; if (!bytes.empty())
        std::memcpy(&v, bytes.data(), std::min<size_t>(4, bytes.size()));
    return v;
}

bool Value::as_bool() const { return !bytes.empty() && bytes[0] != 0; }

void NamedBuiltins::add(uint32_t key, const std::string& current_exe_name) {
    if (key && !current_exe_name.empty()) names_[key] = current_exe_name;
}

bool NamedBuiltins::describe(uint32_t key, OperatorSignature& out) {
    out = OperatorSignature{};
    const auto it = names_.find(key);
    if (it == names_.end()) return false;
    const std::string& n = it->second;
    if (n == "Not") { out.input_widths = {1}; out.output_width = 1; }
    else if (n == "And" || n == "Or") {
        out.input_widths = {1, 1}; out.output_width = 1;
    } else if (n == "AbsoluteFloat" || n == "FloorFloatFloat") {
        out.input_widths = {4}; out.output_width = 4;
    } else if (n == "ToInt32Float") {
        out.input_widths = {4}; out.output_width = 4;
    } else if (n == "AddFloat" || n == "MultiplyFloatFloatFloat" ||
               n == "DivideFloatFloatFloat") {
        out.input_widths = {4, 4}; out.output_width = 4;
    } else if (n == "AddInt" || n == "SubtractInt") {
        out.input_widths = {4, 4}; out.output_width = 4;
    } else if (n == "GreaterThanFloat" || n == "GreaterThanOrEqualsFloat" ||
               n == "NotEqualsFloat" || n == "LessThanFloat" ||
               n == "LessThanOrEqualsFloat" || n == "EqualsInt" ||
               n == "NotEqualsInt" || n == "GreaterThanInt" ||
               n == "GreaterThanOrEqualsInt" || n == "LessThanInt" ||
               n == "LessThanOrEqualsInt" || n == "EnumEqualFunc") {
        out.input_widths = {4, 4}; out.output_width = 1;
    } else return false;
    return true;
}

bool NamedBuiltins::invoke(uint32_t key, const std::vector<Value>& a,
                           Value& out) {
    OperatorSignature signature;
    if (!describe(key, signature) || a.size() != signature.input_widths.size())
        return false;
    for (const Value& v : a) if (!v.known) return false;
    const std::string& n = names_[key];
    auto f32 = [](const Value& v) {
        float f = 0.f; std::memcpy(&f, v.bytes.data(), 4); return f;
    };
    auto i32 = [](const Value& v) { return (int32_t)v.as_u32(); };
    auto put_f32 = [](float f) {
        Value v; v.bytes.resize(4); std::memcpy(v.bytes.data(), &f, 4);
        v.known = true; return v;
    };
    auto put_i32 = [](int32_t i) { return Value::from_u32((uint32_t)i); };

    if (n == "Not") out = Value::from_bool(!a[0].as_bool());
    else if (n == "And") out = Value::from_bool(a[0].as_bool() && a[1].as_bool());
    else if (n == "Or") out = Value::from_bool(a[0].as_bool() || a[1].as_bool());
    else if (n == "AbsoluteFloat") out = put_f32(std::fabs(f32(a[0])));
    else if (n == "FloorFloatFloat") out = put_f32(std::floor(f32(a[0])));
    else if (n == "ToInt32Float") {
        const float value = f32(a[0]);
        if (!std::isfinite(value) ||
            value < static_cast<float>(std::numeric_limits<int32_t>::min()) ||
            value > static_cast<float>(std::numeric_limits<int32_t>::max()))
            return false;
        out = put_i32(static_cast<int32_t>(value));
    }
    else if (n == "AddFloat") out = put_f32(f32(a[0]) + f32(a[1]));
    else if (n == "MultiplyFloatFloatFloat") out = put_f32(f32(a[0]) * f32(a[1]));
    else if (n == "DivideFloatFloatFloat") {
        if (f32(a[1]) == 0.f) return false;
        out = put_f32(f32(a[0]) / f32(a[1]));
    } else if (n == "AddInt")
        out = Value::from_u32(a[0].as_u32() + a[1].as_u32());
    else if (n == "SubtractInt")
        out = Value::from_u32(a[0].as_u32() - a[1].as_u32());
    else if (n == "GreaterThanFloat") out = Value::from_bool(f32(a[0]) > f32(a[1]));
    else if (n == "GreaterThanOrEqualsFloat") out = Value::from_bool(f32(a[0]) >= f32(a[1]));
    else if (n == "NotEqualsFloat") out = Value::from_bool(f32(a[0]) != f32(a[1]));
    else if (n == "LessThanFloat") out = Value::from_bool(f32(a[0]) < f32(a[1]));
    else if (n == "LessThanOrEqualsFloat") out = Value::from_bool(f32(a[0]) <= f32(a[1]));
    else if (n == "EqualsInt" || n == "EnumEqualFunc")
        out = Value::from_bool(a[0].as_u32() == a[1].as_u32());
    else if (n == "NotEqualsInt") out = Value::from_bool(i32(a[0]) != i32(a[1]));
    else if (n == "GreaterThanInt") out = Value::from_bool(i32(a[0]) > i32(a[1]));
    else if (n == "GreaterThanOrEqualsInt") out = Value::from_bool(i32(a[0]) >= i32(a[1]));
    else if (n == "LessThanInt") out = Value::from_bool(i32(a[0]) < i32(a[1]));
    else if (n == "LessThanOrEqualsInt") out = Value::from_bool(i32(a[0]) <= i32(a[1]));
    else return false;
    return true;
}

bool make_instance(const Graph& graph, Instance& out, std::string& error) {
    error.clear(); out = Instance{};
    if (graph.instance_image.size() != graph.header.instance_header_size) {
        error = "instance image size does not match the graph header";
        return false;
    }
    out.graph = &graph;
    out.image = graph.instance_image;
    return true;
}

Evaluation evaluate(const Graph& graph, Instance* instance,
                    const std::vector<Value>& arguments, Host* host)
{
    Evaluation result;
    if (!graph.exact_record_tiling) {
        result.termination = Termination::UntiledGraph;
        result.diagnostics.push_back("record region is not an exact proven-kind tiling");
        return result;
    }
    if (instance && instance->graph != &graph) {
        result.termination = Termination::InvalidGraph;
        result.diagnostics.push_back("expression instance belongs to another graph");
        return result;
    }
    std::map<uint32_t, const Record*> records;
    for (const Record& record : graph.records) records[record.offset] = &record;
    if (records.empty() || records.find(0) == records.end()) {
        result.termination = Termination::Complete;
        return result;
    }
    Slots slots(graph.header.slot_file_size);
    size_t argument_index = 0;
    uint32_t cursor = 0;
    const uint32_t step_limit = std::max<uint32_t>(1u,
        (uint32_t)graph.records.size() * 4u);
    Value last_written;

    while (result.steps++ < step_limit) {
        const auto found = records.find(cursor);
        if (found == records.end()) {
            result.termination = Termination::Complete;
            result.result = last_written;
            return result;
        }
        const Record& record = *found->second;
        uint32_t next = record.next;

        if (record.kind == 0x2c) {
            result.termination = Termination::Return;
            result.result = last_written;
            return result;
        }
        if (record.kind == 0x26 && !record.operands.empty()) {
            const Value condition = materialize(graph, instance, slots,
                                                record.operands[0], 1);
            if (condition.known) {
                if (!condition.as_bool()) next = record.control_target;
            } else {
                ++result.guessed_branches;
                result.diagnostics.push_back("unknown branch condition; followed fall-through");
                last_written.tainted = true;
            }
        } else if (record.kind == 0x28 && !record.operands.empty()) {
            const Value selector = materialize(graph, instance, slots,
                                               record.operands[0], 4);
            if (selector.known) {
                const uint32_t label = selector.as_u32();
                for (size_t i = 0; i < record.dispatch_labels.size(); ++i)
                    if (record.dispatch_labels[i] == label) {
                        next = record.dispatch_targets[i];
                        break;
                    }
            } else {
                ++result.guessed_branches;
                result.diagnostics.push_back("unknown dispatch selector; followed merge successor");
                last_written.tainted = true;
            }
        } else if (record.kind == 0x27) {
            if (!record.operands.empty()) {
                const Value target = materialize(graph, instance, slots,
                                                 record.operands[0], 4);
                if (target.known) next = target.as_u32();
                else {
                    ++result.approximated_indirect_jumps;
                    result.diagnostics.push_back("unknown indirect jump; followed stored successor");
                }
            }
        } else if (record.operator_key == kParameterValue ||
                   record.operator_key == kParameterObject) {
            const Operand* output = last_slot(record);
            if (output) {
                Value value = argument_index < arguments.size()
                    ? arguments[argument_index++] : unknown(4);
                const uint32_t width = (uint32_t)std::max<size_t>(1, value.bytes.size());
                slots.write(output->offset, width, value);
                last_written = value;
            }
        } else if (record.operator_key == kSink) {
            if (!record.operands.empty()) {
                const Operand& source = record.operands.back();
                uint32_t width = 4;
                const auto wi = slots.widths.find(source.offset);
                if (source.region == 2 && wi != slots.widths.end()) width = wi->second;
                result.result = materialize(graph, instance, slots, source, width);
                last_written = result.result;
            }
        } else if (record.operator_key == kTerminator) {
            result.termination = Termination::Complete;
            result.result = last_written;
            return result;
        } else if (record.operator_key == kVariableStore) {
            if (instance && record.operands.size() >= 2) {
                const Operand* value_operand = nullptr;
                const Operand* tag = nullptr;
                for (const Operand& operand : record.operands) {
                    if (!value_operand && operand.region == 2) value_operand = &operand;
                    if (!tag && operand.region == 0) tag = &operand;
                }
                if (value_operand && tag) {
                    uint32_t width = 4;
                    const auto wi = slots.widths.find(value_operand->offset);
                    if (wi != slots.widths.end()) width = wi->second;
                    instance->variables[tag->offset] =
                        slots.read(value_operand->offset, width);
                }
            }
        } else if (!record.has_operator && record.kind >= 0x1e &&
                   record.kind <= 0x25) {
            const uint32_t width = move_width(record);
            const Operand* output = last_slot(record);
            if (width && output && !record.operands.empty()) {
                const Operand& source = record.operands.front();
                Value value = materialize(graph, instance, slots, source, width);
                slots.write(output->offset, width, value);
                last_written = value;
            } else if (!width) {
                result.diagnostics.push_back("unmeasured move width withheld");
                last_written.tainted = true;
            }
        } else if (record.operator_key) {
            OperatorSignature signature;
            const bool described = host && host->describe(record.operator_key, signature);
            const Operand* output = signature.output_width ? last_slot(record) : nullptr;
            size_t available = record.operands.size();
            if (output && available) --available;
            if (!described || available != signature.input_widths.size() ||
                (signature.output_width && !output)) {
                add_unresolved(result, record.operator_key);
                last_written.tainted = true;
            } else {
                std::vector<Value> args;
                for (size_t i = 0; i < available; ++i)
                    args.push_back(materialize(graph, instance, slots,
                                               record.operands[i],
                                               signature.input_widths[i]));
                Value value;
                if (host->invoke(record.operator_key, args, value)) {
                    for (const Value& arg : args)
                        value.tainted = value.tainted || arg.tainted || !arg.known;
                    if (output && signature.output_width) {
                        if (value.bytes.size() < signature.output_width)
                            value = unknown(signature.output_width);
                        slots.write(output->offset, signature.output_width, value);
                        last_written = value;
                    }
                } else {
                    add_unresolved(result, record.operator_key);
                    last_written.tainted = true;
                }
            }
        }

        if (!next || next <= cursor || records.find(next) == records.end()) {
            result.termination = Termination::Complete;
            if (!result.result.known && result.result.bytes.empty()) result.result = last_written;
            return result;
        }
        cursor = next;
    }
    result.termination = Termination::StepLimit;
    result.result = last_written;
    result.result.tainted = true;
    result.diagnostics.push_back("step limit reached");
    return result;
}

}} // namespace bf6::expression
