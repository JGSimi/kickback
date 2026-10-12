#!/usr/bin/env python3
"""Torna um runtime copiado relocável: troca referências Mach-O absolutas à pasta de build
(install names, dependências e LC_RPATH) por @loader_path relativo e reassina ad-hoc.

Uso: relocate.py <runtime copiado> <prefixo antigo (ex.: .../KickBack/runtime)>
Sai com erro se sobrar alguma referência ao prefixo antigo.
"""
import os
import subprocess
import sys

MAGIC = {b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf", b"\xbe\xba\xfe\xca"}


def is_macho(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) in MAGIC
    except OSError:
        return False


def out(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def load_paths(path):
    """(id, dependências, rpaths) de um Mach-O; universal: a primeira arquitetura basta."""
    deps, rpaths, ident, cmd = [], [], None, None
    for line in out("otool", "-l", path).splitlines():
        line = line.strip()
        if line.startswith("Load command") and deps and line.endswith(" 0"):
            break  # segunda arquitetura de um binário universal
        if line.startswith("cmd "):
            cmd = line.split()[1]
        elif line.startswith(("name ", "path ")):
            value = line.split(" ", 1)[1].rsplit(" (offset", 1)[0]
            if cmd == "LC_ID_DYLIB":
                ident = value
            elif cmd in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB"):
                deps.append(value)
            elif cmd == "LC_RPATH":
                rpaths.append(value)
    return ident, deps, rpaths


def main(root, old):
    root, old = os.path.abspath(root), old.rstrip("/")
    fixed = 0
    for d, _, files in os.walk(root):
        for name in files:
            f = os.path.join(d, name)
            if os.path.islink(f) or not is_macho(f):
                continue
            ident, deps, rpaths = load_paths(f)

            def rel(p):
                target = os.path.join(root, os.path.relpath(p, old))
                return "@loader_path/" + os.path.relpath(target, d)

            args = []
            if ident and ident.startswith(old):
                args += ["-id", "@rpath/" + os.path.basename(ident)]
            for p in deps:
                if p.startswith(old):
                    args += ["-change", p, rel(p)]
            for p in rpaths:
                if p.startswith(old):
                    args += ["-rpath", p, rel(p)]
            if args:
                subprocess.run(["install_name_tool", *args, f], check=True, capture_output=True)
                subprocess.run(["codesign", "-f", "-s", "-", f], check=True, capture_output=True)
                fixed += 1
    # conferência: nada pode continuar apontando para a pasta de build
    left = []
    for d, _, files in os.walk(root):
        for name in files:
            f = os.path.join(d, name)
            if not os.path.islink(f) and is_macho(f) and old in out("otool", "-l", f):
                left.append(f)
    print(f"relocate: {fixed} arquivos ajustados")
    if left:
        sys.exit("relocate: ainda referenciam o prefixo antigo:\n  " + "\n  ".join(left))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
