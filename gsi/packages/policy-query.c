/* Read-only TE query against Android's matching libsepol, including attributes
 * and conditional allows conservatively. This is not a full MLS/DAC audit. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sepol/policydb/policydb.h>
#include <sepol/policydb/avtab.h>

static int matches(policydb_t *policy, unsigned concrete, unsigned rule) {
    return concrete == rule || ebitmap_get_bit(&policy->type_attr_map[concrete - 1], rule - 1);
}
static void names(symtab_t *table, const char **permissions) {
    for (unsigned slot = 0; slot < table->table->size; slot++)
        for (hashtab_ptr_t node = table->table->htable[slot]; node; node = node->next) {
            perm_datum_t *permission = node->datum;
            if (permission->s.value > 0 && permission->s.value <= 32)
                permissions[permission->s.value - 1] = node->key;
        }
}
static void query(policydb_t *policy, avtab_t *table, unsigned source, unsigned target, const char *kind) {
    for (unsigned slot = 0; slot < table->nslot; slot++)
        for (avtab_ptr_t node = table->htable[slot]; node; node = node->next) {
            if (!(node->key.specified & AVTAB_ALLOWED) || !matches(policy, source, node->key.source_type)
                || (target && !matches(policy, target, node->key.target_type))) continue;
            const char *class_name = policy->p_class_val_to_name[node->key.target_class - 1];
            if (strcmp(kind, "*") && strcmp(kind, class_name)) continue;
            class_datum_t *object_class = policy->class_val_to_struct[node->key.target_class - 1];
            const char *permissions[32] = {0};
            if (object_class->comdatum) names(&object_class->comdatum->permissions, permissions);
            names(&object_class->permissions, permissions);
            printf("%s\t%s\t%s\t", policy->p_type_val_to_name[node->key.source_type - 1],
                   policy->p_type_val_to_name[node->key.target_type - 1], class_name);
            for (unsigned bit = 0; bit < 32; bit++)
                if (node->datum.data & (1U << bit)) printf("%s ", permissions[bit] ? permissions[bit] : "UNKNOWN");
            putchar('\n');
        }
}
int main(int argc, char **argv) {
    if (argc != 5) { fprintf(stderr, "policy-query POLICY SOURCE TARGET_OR_* CLASS_OR_*\n"); return 2; }
    policydb_t policy;
    policy_file_t file;
    if (policydb_init(&policy)) return 3;
    policy_file_init(&file);
    file.type = PF_USE_STDIO;
    file.fp = fopen(argv[1], "rb");
    if (!file.fp || policydb_read(&policy, &file, 0)) return 4;
    fclose(file.fp);
    type_datum_t *source = hashtab_search(policy.p_types.table, argv[2]);
    type_datum_t *target = strcmp(argv[3], "*") ? hashtab_search(policy.p_types.table, argv[3]) : NULL;
    if (!source || (strcmp(argv[3], "*") && !target)) return 5;
    query(&policy, &policy.te_avtab, source->s.value, target ? target->s.value : 0, argv[4]);
    query(&policy, &policy.te_cond_avtab, source->s.value, target ? target->s.value : 0, argv[4]);
    policydb_destroy(&policy);
    return 0;
}
