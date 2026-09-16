#!/usr/bin/env python3
"""Execute the actual Unreal Build.cs recipe function in an isolated .NET harness."""
import argparse
import os
from pathlib import Path
import subprocess
from xml.sax.saxutils import escape

PROGRAM = r'''
using System;
using System.IO;
using System.Linq;

class Program
{
    static int Failures;
    static void Expect(bool Ok, string Label) { Console.WriteLine((Ok ? "PASS " : "FAIL ") + Label); if (!Ok) ++Failures; }
    static void CopyTree(string From, string To)
    {
        foreach (string FilePath in Directory.EnumerateFiles(From, "*", SearchOption.AllDirectories))
        {
            string Target = Path.Combine(To, Path.GetRelativePath(From, FilePath));
            Directory.CreateDirectory(Path.GetDirectoryName(Target)!);
            File.Copy(FilePath, Target, true);
        }
    }
    static int Main(string[] Args)
    {
        string RealPlugin = Path.GetFullPath(Args[0]);
        string Headers = BF6HighPoly.FindReaderHeaders(RealPlugin);
        string Real = BF6HighPoly.ComputeCacheCodeSignature(RealPlugin, Headers, _ => {});
        Expect(Real.Length == 64, "real installed source tree has a code fingerprint");
        Expect(BF6HighPoly.ComputeCacheCodeSignature(RealPlugin, Headers, _ => {}) == Real, "real fingerprint is reproducible");
        string Fixture = Path.Combine(Path.GetFullPath(Args[1]), "fixtures", Guid.NewGuid().ToString("N"));
        string Plugins = Path.Combine(Fixture, "Plugins");
        string Plugin = Path.Combine(Plugins, "BF6HighPoly");
        string TestHeaders = Path.Combine(Plugins, "BF6UnrealSDK", "Source", "ThirdParty", "libbf6", "include");
        CopyTree(Path.Combine(RealPlugin, "Source"), Path.Combine(Plugin, "Source"));
        CopyTree(Headers, TestHeaders);
        Directory.CreateDirectory(Path.Combine(Plugin, "Resources"));
        string Contract = Path.Combine(Plugin, "Resources", "cache_dependencies.json");
        File.Copy(Path.Combine(RealPlugin, "Resources", "cache_dependencies.json"), Contract);
        string Signature() => BF6HighPoly.ComputeCacheCodeSignature(Plugin, TestHeaders, _ => {});
        Expect(Signature() == Real, "relocated identical files keep fingerprint");
        Expect(BF6HighPoly.FindReaderHeaders(Plugin) == TestHeaders, "release sibling plugin layout finds SDK");
        Expect(BF6HighPoly.FindReaderHeaders(Path.Combine(Plugins, "Add-Ons", "BF6HighPoly")) == TestHeaders, "Add-Ons plugin layout finds SDK");
        bool Refused = false;
        try { BF6HighPoly.FindReaderHeaders(Path.Combine(Fixture, "missing", "BF6HighPoly")); } catch { Refused = true; }
        Expect(Refused, "missing SDK is refused clearly");
        string Private = Path.Combine(Plugin, "Source", "BF6HighPoly", "Private");
        File.AppendAllText(Path.Combine(Private, "BF6HighPolyMenu.cpp"), "\n// cosmetic test\n");
        File.AppendAllText(Path.Combine(Private, "BF6HighPolyPreparationMenu.inc"), "\n// progress display test\n");
        Expect(Signature() == Real, "menu and preparation display edits preserve fingerprint");
        File.AppendAllText(Path.Combine(Private, "BF6HighPolyCore.cpp"), "\n// decoder change control\n");
        string Decoder = Signature();
        Expect(Decoder != Real, "decoder change invalidates");
        File.WriteAllText(Path.Combine(Private, "FutureDecoder.cpp"), "// unknown new producer\n");
        string Added = Signature();
        Expect(Added != Decoder, "unknown new code invalidates by default");
        File.AppendAllText(Path.Combine(TestHeaders, "bf6_core.h"), "\n// reader layout change\n");
        Expect(Signature() != Added, "reader header change invalidates");
        File.Delete(Path.Combine(Private, "BF6HighPolyCore.cpp"));
        Refused = false;
        try { Signature(); } catch { Refused = true; }
        Expect(Refused, "missing required decoder refuses fingerprint");
        File.WriteAllText(Contract, "{}");
        Refused = false;
        try { Signature(); } catch { Refused = true; }
        Expect(Refused, "invalid dependency contract refuses fingerprint");
        Console.WriteLine("FAILURES " + Failures);
        return Failures == 0 ? 0 : 1;
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-root", type=Path, required=True)
    parser.add_argument("--unreal-plugin", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    dotnet = next((args.engine_root / "Engine/Binaries/ThirdParty/DotNet").rglob("dotnet.exe"))
    assemblies = args.engine_root / "Engine/Binaries/DotNET/UnrealBuildTool"
    rules = args.unreal_plugin / "Source/BF6HighPoly/BF6HighPoly.Build.cs"
    references = "\n".join(f'<Reference Include="{escape(str(file))}" />' for file in assemblies.glob("*.dll"))
    project = f'''<Project Sdk="Microsoft.NET.Sdk">
<PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><Nullable>enable</Nullable><EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup>
<ItemGroup><Compile Include="Program.cs" /><Compile Include="{escape(str(rules))}" />{references}</ItemGroup>
</Project>'''
    (args.output / "RecipeVerification.csproj").write_text(project, encoding="utf-8")
    (args.output / "Program.cs").write_text(PROGRAM, encoding="utf-8")
    environment = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1", DOTNET_GENERATE_ASPNET_CERTIFICATE="false")
    run = subprocess.run([str(dotnet), "run", "--project", str(args.output / "RecipeVerification.csproj"), "--", str(args.unreal_plugin), str(args.output)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment)
    (args.output / "verification.log").write_text(run.stdout, encoding="utf-8")
    print(run.stdout)
    return run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
