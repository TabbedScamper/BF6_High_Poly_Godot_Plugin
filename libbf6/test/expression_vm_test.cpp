#include "expression_vm.h"

#include <cstdio>

namespace {

static const uint32_t kAdd = 0xce900afcu;

class AddHost final : public bf6::expression::Host {
public:
    bool describe(uint32_t key, bf6::expression::OperatorSignature& out) override {
        if (key != kAdd) return false;
        out.input_widths = {4, 4};
        out.output_width = 4;
        return true;
    }

    bool invoke(uint32_t key, const std::vector<bf6::expression::Value>& args,
                bf6::expression::Value& out) override {
        if (key != kAdd || args.size() != 2 || !args[0].known || !args[1].known)
            return false;
        out = bf6::expression::Value::from_u32(args[0].as_u32() + args[1].as_u32());
        return true;
    }
};

bf6::expression::Graph arithmetic_graph() {
    using namespace bf6::expression;
    Graph g;
    g.exact_record_tiling = true;
    g.header.slot_file_size = 16;
    g.constant_pool = {5, 0, 0, 0};
    Record source;
    source.offset = 0; source.next = 20; source.kind = 0x01;
    source.has_operator = true; source.operator_key = 0x9a38f86fu;
    source.operands = {{0, 0}, {2, 0}};
    Record add;
    add.offset = 20; add.next = 48; add.kind = 0x02;
    add.has_operator = true; add.operator_key = kAdd;
    add.operands = {{2, 0}, {0, 0}, {2, 4}};
    Record sink;
    sink.offset = 48; sink.next = 68; sink.kind = 0x01;
    sink.has_operator = true; sink.operator_key = 0x26730cb8u;
    sink.operands = {{0, 0}, {2, 4}};
    Record done;
    done.offset = 68; done.kind = 0x2c;
    g.records = {source, add, sink, done};
    return g;
}

} // namespace

int main() {
    using namespace bf6::expression;
    Graph graph = arithmetic_graph();
    AddHost host;
    const Evaluation real = evaluate(graph, nullptr, {Value::from_u32(7)}, &host);
    NamedBuiltins builtins;
    builtins.add(kAdd, "AddFloat");
    Graph named_graph = graph;
    const float five = 5.f;
    std::memcpy(named_graph.constant_pool.data(), &five, 4);
    float seven = 7.f;
    Value float_seven; float_seven.bytes.resize(4);
    std::memcpy(float_seven.bytes.data(), &seven, 4); float_seven.known = true;
    const Evaluation current_name_path = evaluate(named_graph, nullptr,
                                                  {float_seven}, &builtins);
    const Evaluation null_control = evaluate(graph, nullptr,
                                             {Value::from_u32(7)}, nullptr);

    Graph untiled = graph;
    untiled.exact_record_tiling = false;
    const Evaluation tiling_control = evaluate(untiled, nullptr,
                                               {Value::from_u32(7)}, &host);

    Instance instance;
    std::string error;
    graph.header.instance_header_size = 4;
    graph.instance_image = {1, 2, 3, 4};
    const bool instance_ok = make_instance(graph, instance, error);
    Graph other = graph;
    const Evaluation ownership_control = evaluate(other, &instance, {}, &host);

    std::printf("DiceExpression evaluator controls\n");
    std::printf("  exact add result: %u; known/tainted: %d/%d\n",
                real.result.as_u32(), real.result.known ? 1 : 0,
                real.result.tainted ? 1 : 0);
    std::printf("  null-host unresolved: %zu; known/tainted: %d/%d\n",
                null_control.unresolved_keys.size(),
                null_control.result.known ? 1 : 0,
                null_control.result.tainted ? 1 : 0);
    float named_result = 0.f;
    if (current_name_path.result.bytes.size() >= 4)
        std::memcpy(&named_result, current_name_path.result.bytes.data(), 4);
    std::printf("  current-name builtin add: %.1f\n", named_result);
    std::printf("  untiled control: %d\n",
                tiling_control.termination == Termination::UntiledGraph ? 1 : 0);
    std::printf("  instance copy/ownership control: %d/%d\n",
                instance_ok && instance.image == graph.instance_image ? 1 : 0,
                ownership_control.termination == Termination::InvalidGraph ? 1 : 0);

    return real.result.known && !real.result.tainted &&
           real.result.as_u32() == 12 &&
           current_name_path.result.known && named_result == 12.f &&
           null_control.unresolved_keys.size() == 1 &&
           !null_control.result.known && null_control.result.tainted &&
           tiling_control.termination == Termination::UntiledGraph &&
           instance_ok && instance.image == graph.instance_image &&
           ownership_control.termination == Termination::InvalidGraph ? 0 : 1;
}
