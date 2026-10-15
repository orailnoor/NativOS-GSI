#!/usr/bin/python3
"""Scoped native-app executable-storage extension; preserve every other pair."""
from pathlib import Path
import re
import sys

base = Path(sys.argv[1]).read_text()
source = re.findall(r'\(typeattributeset (\w+) \(and \(domain\s*\) \(not \(appdomain overlay_remounter\s*\)\)\)\)', base)
target = re.findall(r'\(typeattributeset (\w+) \(and \(data_file_type\s*\) \(not \(system_data_file apk_data_file dalvikcache_data_file apex_art_data_file\s*\)\)\)\)', base)
if len(source) != 1 or len(target) != 1:
    raise SystemExit('Unsupported private-data execution assertion layout; refusing unchecked platform exception')
assertion = f'(neverallow {source[0]} {target[0]} (file (execute execute_no_trans)))'
if base.count(assertion) != 1:
    raise SystemExit('Expected exactly one private-data execution assertion')
# Only the native package domain may execute its own writable environment.
# Every other original source/target pair is still prohibited. Android app
# transitions, ART JIT, vendor policy and ordinary home execution are unchanged.
replacement = '\n'.join((
    '(typeattribute nativos_other_data_executor)',
    f'(typeattributeset nativos_other_data_executor (and ({source[0]}) (not (nativos_package))))',
    '(typeattribute nativos_other_executable_data)',
    f'(typeattributeset nativos_other_executable_data (and ({target[0]}) (not (nativos_package_file))))',
    f'(neverallow nativos_other_data_executor {target[0]} (file (execute execute_no_trans)))',
    '(neverallow nativos_package nativos_other_executable_data (file (execute execute_no_trans)))',
))
base = base.replace(assertion, replacement)
# A second platform assertion also covers all non-system/vendor executables.
# Apply the SAME exact pair exception; never exempt the whole worker domain.
source2 = re.findall(r'\(typeattributeset (\w+) \(and \(domain\s*\) \(not \(appdomain app_zygote mediaextractor mediaswcodec shell su webview_zygote zygote overlay_remounter system_server_startup\s*\)\)\)\)', base)
target2 = re.findall(r'\(typeattributeset (\w+) \(and \(file_type\s*\) \(not \(exec_type system_file_type vendor_file_type system_lib_file system_bootstrap_lib_file system_linker_exec postinstall_file\s*\)\)\)\)', base)
if len(source2) != 1 or len(target2) != 1:
    raise SystemExit('Unsupported non-system execution assertion layout')
assertion2 = f'(neverallow {source2[0]} {target2[0]} (file (execute)))'
if base.count(assertion2) != 1:
    raise SystemExit('Expected exactly one non-system execution assertion')
replacement2 = '\n'.join((
    '(typeattribute nativos_other_nonsystem_executor)',
    f'(typeattributeset nativos_other_nonsystem_executor (and ({source2[0]}) (not (nativos_package))))',
    '(typeattribute nativos_other_nonsystem_code)',
    f'(typeattributeset nativos_other_nonsystem_code (and ({target2[0]}) (not (nativos_package_file))))',
    f'(neverallow nativos_other_nonsystem_executor {target2[0]} (file (execute)))',
    '(neverallow nativos_package nativos_other_nonsystem_code (file (execute)))',
))
base = base.replace(assertion2, replacement2)
Path(sys.argv[3]).write_text(base + '\n' + Path(sys.argv[2]).read_text())
