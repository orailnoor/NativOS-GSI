#!/usr/bin/env bash
set -euo pipefail
task_schema_dir=$(mktemp -d /tmp/nativos-drawer-schema.XXXXXX)
cp "${ROOTFS_TREE:?Set ROOTFS_TREE}/usr/share/glib-2.0/schemas/"*.xml "$task_schema_dir/"
cp "$(dirname "$0")/99-nativos-app-drawer.gschema.override" "$task_schema_dir/"
glib-compile-schemas --strict --dry-run "$task_schema_dir"
printf 'All-apps schema override validation passed\n'
