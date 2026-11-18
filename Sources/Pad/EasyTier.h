// iPad 端内嵌的 EasyTier（easytier-contrib/easytier-ffi）
#include <stddef.h>

typedef struct { const char *key; const char *value; } KeyValuePair;

int parse_config(const char *cfg_str);
int run_network_instance(const char *cfg_str);
int retain_network_instance(const char *const *inst_names, size_t length);
int collect_network_infos(KeyValuePair *infos, size_t max_length);
void get_error_msg(const char **out);
void free_string(const char *s);
