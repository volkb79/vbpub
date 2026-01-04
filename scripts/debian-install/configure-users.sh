#!/bin/bash
#
# User Configuration Script for Debian Systems
# Configures editor, file manager, and monitoring tool settings for root and future users
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
    echo ""
    echo -e "${GREEN}==>${NC} ${BLUE}$*${NC}"
    echo ""
}

# Configure nano for a user
configure_nano() {
    local target_user="$1"
    local target_home="$2"
    local nanorc="${target_home}/.nanorc"
    
    log_info "Configuring nano for ${target_user}..."
    
    cat > "$nanorc" <<'EOF'
# Nano Configuration
# Visual width of tab
set tabsize 4

# Soft wrap long lines
set softwrap

# Convert tabs to spaces (Python/VSCode compatibility)
set tabstospaces

# Enable mouse support
set mouse

# Show line numbers
set linenumbers

# Enable smooth scrolling
set smooth

# Automatically indent new lines
set autoindent

# Use bold instead of reverse video for the title bar
set boldtext

# Enable syntax highlighting
include /usr/share/nano/*.nanorc
EOF
    
    chown "${target_user}:${target_user}" "$nanorc" 2>/dev/null || true
    chmod 644 "$nanorc"
    
    log_success "Nano configured for ${target_user}"
}

# Configure Midnight Commander for a user
configure_mc() {
    local target_user="$1"
    local target_home="$2"
    local mc_dir="${target_home}/.config/mc"
    
    log_info "Configuring Midnight Commander for ${target_user}..."
    
    # Create MC config directory
    mkdir -p "$mc_dir"
    
    # Main MC configuration
    cat > "${mc_dir}/ini" <<'EOF'
[Midnight-Commander]
skin=modarin256-defbg-thin
shadows=false
use_internal_view=true
use_internal_edit=true
auto_save_setup=true
pause_after_run=1
shell_patterns=true
auto_menu=false
drop_menus=false
wrap_mode=true
confirm_delete=true
confirm_overwrite=true
confirm_execute=true
confirm_exit=false
safe_delete=false
mouse_repeat_rate=100
double_click_speed=250
old_esc_mode=false
cd_follows_links=true
safe_overwrite=false

[Layout]
message_visible=true
keybar_visible=true
xterm_title=true
output_lines=0
command_prompt=true
menubar_visible=true
free_space=true

[Misc]
ftpfs_password=anonymous@
display_codepage=UTF-8
source_codepage=Other_8_bit
clipboard_store=
clipboard_paste=
EOF
    
    # Panel configuration
    cat > "${mc_dir}/panels.ini" <<'EOF'
[New Left Panel]
display=listing
reverse=false
case_sensitive=true
exec_first=false
sort_order=name
list_mode=full
brief_cols=2
user_format=half type name | size | owner | group | perm | atime
user_mini_status=false
filter_flags=7
list_format=user

[New Right Panel]
display=listing
reverse=false
case_sensitive=true
exec_first=false
sort_order=name
list_mode=full
brief_cols=2
user_format=half type name | size | owner | group | perm | atime
user_mini_status=false
filter_flags=7
list_format=user

[Dirs]
current_is_left=true
EOF
    
    chown -R "${target_user}:${target_user}" "$mc_dir" 2>/dev/null || true
    chmod -R 755 "$mc_dir"
    
    log_success "Midnight Commander configured for ${target_user}"
}

# Configure iftop for a user
configure_iftop() {
    local target_user="$1"
    local target_home="$2"
    local iftoprc="${target_home}/.iftoprc"
    
    log_info "Configuring iftop for ${target_user}..."
    
    cat > "$iftoprc" <<'EOF'
# iftop Configuration
# Show bar graphs
show-bars: yes

# Show port numbers
port-resolution: yes

# Show DNS names (can be slow)
dns-resolution: no

# Show source/destination
show-totals: yes

# Display bandwidth in bits or bytes
log-scale: no

# Sort by total bandwidth
sort: 2bit

# Line display mode (one-line-both, one-line-sent, one-line-received, two-line)
line-display: two-line

# Port display (off, source-only, destination-only, on)
port-display: on

# Number of bars in histogram
num-lines: 10
EOF
    
    chown "${target_user}:${target_user}" "$iftoprc" 2>/dev/null || true
    chmod 644 "$iftoprc"
    
    log_success "iftop configured for ${target_user}"
}

# Configure htop for a user
configure_htop() {
    local target_user="$1"
    local target_home="$2"
    local htop_dir="${target_home}/.config/htop"
    
    log_info "Configuring htop for ${target_user}..."
    
    mkdir -p "$htop_dir"
    
    cat > "${htop_dir}/htoprc" <<'EOF'
# htop Configuration
fields=0 48 17 18 38 39 40 2 46 47 49 1
sort_key=46
sort_direction=-1
tree_sort_key=0
tree_sort_direction=1
hide_kernel_threads=1
hide_userland_threads=0
shadow_other_users=0
show_thread_names=0
show_program_path=1
highlight_base_name=1
highlight_deleted_exe=1
shadow_distribution_path_prefix=0
highlight_megabytes=1
highlight_threads=1
highlight_changes=0
highlight_changes_delay_secs=5
find_comm_in_cmdline=1
strip_exe_from_cmdline=1
show_merged_command=0
header_margin=1
screen_tabs=1
detailed_cpu_time=0
cpu_count_from_one=0
show_cpu_usage=1
show_cpu_frequency=0
show_cpu_temperature=0
degree_fahrenheit=0
update_process_names=0
account_guest_in_cpu_meter=0
color_scheme=0
enable_mouse=1
delay=15
hide_function_bar=0
header_layout=two_50_50
column_meters_0=AllCPUs Memory Swap
column_meter_modes_0=1 1 1
column_meters_1=Tasks LoadAverage Uptime
column_meter_modes_1=2 2 2
tree_view=0
tree_view_always_by_pid=0
all_branches_collapsed=0
EOF
    
    chown -R "${target_user}:${target_user}" "$htop_dir" 2>/dev/null || true
    chmod -R 755 "$htop_dir"
    
    log_success "htop configured for ${target_user}"
}

# Configure all tools for a user
configure_user() {
    local target_user="$1"
    local target_home="$2"
    
    log_step "Configuring user: ${target_user}"
    
    if [ ! -d "$target_home" ]; then
        log_warn "Home directory ${target_home} does not exist, skipping"
        return 1
    fi
    
    configure_nano "$target_user" "$target_home"
    configure_mc "$target_user" "$target_home"
    configure_iftop "$target_user" "$target_home"
    configure_htop "$target_user" "$target_home"
    
    log_success "User ${target_user} configuration complete"
}

# Configure default skeleton for new users
configure_skel() {
    log_step "Configuring /etc/skel for new users"
    
    local skel_dir="/etc/skel"
    
    # Configure nano
    cat > "${skel_dir}/.nanorc" <<'EOF'
set tabsize 4
set softwrap
set tabstospaces
set mouse
set linenumbers
set smooth
set autoindent
set boldtext
include /usr/share/nano/*.nanorc
EOF
    
    # Configure MC
    mkdir -p "${skel_dir}/.config/mc"
    
    cat > "${skel_dir}/.config/mc/ini" <<'EOF'
[Midnight-Commander]
skin=modarin256-defbg-thin
shadows=false
use_internal_view=true
use_internal_edit=true
EOF
    
    cat > "${skel_dir}/.config/mc/panels.ini" <<'EOF'
[New Left Panel]
list_format=user
user_format=half type name | size | owner | group | perm | atime

[New Right Panel]
list_format=user
user_format=half type name | size | owner | group | perm | atime

[Dirs]
current_is_left=true
EOF
    
    # Configure iftop
    cat > "${skel_dir}/.iftoprc" <<'EOF'
show-bars: yes
port-resolution: yes
dns-resolution: no
show-totals: yes
sort: 2bit
line-display: two-line
port-display: on
EOF
    
    # Configure htop
    mkdir -p "${skel_dir}/.config/htop"
    cat > "${skel_dir}/.config/htop/htoprc" <<'EOF'
fields=0 48 17 18 38 39 40 2 46 47 49 1
sort_key=46
sort_direction=-1
hide_kernel_threads=1
show_program_path=1
highlight_base_name=1
enable_mouse=1
color_scheme=0
EOF
    
    log_success "/etc/skel configured for new users"
}

# Install required packages
install_packages() {
    log_step "Installing required packages"
    
    local packages="nano mc iftop htop"
    
    apt-get update -qq
    apt-get install -y $packages
    
    log_success "Packages installed: $packages"
}

# Main function
main() {
    log_step "User Configuration Script"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Install packages
    install_packages
    
    # Configure /etc/skel for new users
    configure_skel
    
    # Configure root
    configure_user "root" "/root"
    
    # Configure existing regular users
    log_step "Configuring existing users"
    while IFS=: read -r username _ uid _ _ homedir _; do
        # Only configure regular users (UID >= 1000) with valid home directories
        if [ "$uid" -ge 1000 ] && [ -d "$homedir" ] && [ "$username" != "nobody" ]; then
            configure_user "$username" "$homedir"
        fi
    done < /etc/passwd
    
    log_step "Configuration Complete"
    log_success "All users configured successfully"
    log_info "New users will automatically receive these configurations"
}

# Run main if not sourced
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
