"""Backport a verified stock SELinux class interface without generic allow rules.

Only literal stock memfd rules for existing platform symbols are copied.
Anonymous stock attributes are renamed and restricted to existing symbols.
No existing regular-file rule, neverallow, or class ordering is removed.
"""
import hashlib
import json
import pathlib
import re
import sys

source_path, reference_path, output_path, report_path = map(pathlib.Path, sys.argv[1:])
base = source_path.read_text()
stock = reference_path.read_text()
expected_reference = 'ebc015e54aa3aafdf89230ffd2c48d7e91292317e783025ec2582527dab18b08'
if hashlib.sha256(reference_path.read_bytes()).hexdigest() != expected_reference:
    raise SystemExit('Stock policy reference checksum mismatch')
symbols = set(re.findall(r'^\((?:type|typeattribute|typealias)\s+([^\s()]+)', base, re.M))
base_order = re.findall(r'^\(classorder .*$', base, re.M)
stock_order = re.findall(r'^\(classorder .*$', stock, re.M)
definitions = re.findall(r'^\(class(?:common)? memfd_file .*$', stock, re.M)
if len(base_order) != 1 or len(stock_order) != 1 or len(definitions) != 2:
    raise SystemExit('Unexpected class interface')
if '(class memfd_file ' in base:
    raise SystemExit('Already contains memfd_file; refuse duplicate adapter')
if stock_order[0].replace('memfd_file ', '') != base_order[0]:
    raise SystemExit('Additional class-order changes need separate review')
base_common = re.findall(r'^\(common file .*$', base, re.M)
stock_common = re.findall(r'^\(common file .*$', stock, re.M)
if len(base_common) != 1 or base_common != stock_common:
    raise SystemExit('File permission interface differs')
rules = re.findall(r'^\((?:allow|neverallow|dontaudit|auditallow) [^\n]*\(memfd_file [^\n]*$', stock, re.M)
rules += re.findall(r'^\(allowx [^\n]*\(ioctl memfd_file [^\n]*$', stock, re.M)
other = [line for line in stock.splitlines() if 'memfd_file' in line and line not in rules
         and not line.startswith('(class')]
if other:
    raise SystemExit(f'Unhandled stock memfd statements: {other[:3]}')
adapter, omitted, attributes = [], [], {}
for rule in rules:
    match = re.fullmatch(r'\((allow|neverallow|dontaudit|auditallow) (\S+) (\S+) \(memfd_file \(([^()]*)\)\)\)', rule)
    if not match:
        match = re.fullmatch(r'\((allowx) (\S+) (\S+) (\(ioctl memfd_file \(\(range 0x[0-9a-f]+ 0x[0-9a-f]+\)\)\))\)', rule)
    if not match:
        raise SystemExit('Unsupported stock rule syntax')
    action, source, target, permissions = match.groups()
    replacements = {}
    for symbol in (source, target):
        if symbol == 'self' or (symbol in symbols and not symbol.startswith('base_typeattr_')):
            continue
        if symbol.startswith('base_typeattr_'):
            expr_match = re.findall(r'^\(typeattributeset ' + re.escape(symbol) + r' (.*)\)$', stock, re.M)
            if len(expr_match) != 1:
                raise SystemExit(f'Unresolved stock attribute: {symbol}')
            expression = expr_match[0]
            identifiers = set(re.findall(r'[A-Za-z_][A-Za-z_0-9]*', expression)) - {'and', 'or', 'not', 'all'}
            missing = identifiers - symbols
            # Only absent stock domains may be omitted from an exclusion set.
            # An unknown positive-set member or nested anonymous attr needs review.
            for missing_symbol in missing:
                if not re.search(r'\(not \([^()]*\b' + re.escape(missing_symbol) + r'\b[^()]*\)\)', expression):
                    raise SystemExit(f'Unknown positive attribute member: {missing_symbol}')
                expression = re.sub(r'\b' + re.escape(missing_symbol) + r'\b\s*', '', expression)
            name = 'nativos_memfd_compat_' + symbol.removeprefix('base_typeattr_')
            attributes[name] = {'expression': expression, 'absent_exclusions': sorted(missing)}
            replacements[symbol] = name
        else:
            if action == 'neverallow':
                raise SystemExit(f'Cannot omit stock security assertion: {rule}')
            omitted.append({'rule': rule, 'reason': f'stock-only symbol absent from GSI: {symbol}'})
            break
    else:
        for old, new in replacements.items():
            rule = re.sub(r'\b' + re.escape(old) + r'\b', new, rule)
        adapter.append(rule)
for name, item in attributes.items():
    adapter[:0] = [f'(typeattribute {name})', f'(typeattributeset {name} {item["expression"]})']
new = base.replace(base_order[0], '\n'.join(definitions + stock_order))
new += '\n;; Verified stock memfd-only compatibility adapter; original file rules retained.\n' + '\n'.join(adapter) + '\n'
output_path.write_text(new)
report_path.write_text(json.dumps({'reference_sha256': expected_reference, 'copied_rules': len(adapter),
                                 'stock_only_rules_omitted': omitted, 'attributes': attributes,
                                 'regular_file_policy_unchanged': True, 'enforcing_required': True}, indent=2))
print(f'memfd compatibility: copied {len(adapter)} statements; omitted {len(omitted)} absent stock-service rules; kept stock neverallows')
