# Build-time loader only. Installer scripts receive generated product.zsh instead.
# Resolve from this file so callers can run from any working directory.
task_product_config=$(/usr/bin/mktemp) || return 1
if ! python3 "${${(%):-%x}:A:h}/configure.py" --shell-file "$task_product_config"; then
  /bin/rm -f "$task_product_config"
  return 1
fi
source "$task_product_config"
/bin/rm -f "$task_product_config"
unset task_product_config
