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

# Nano configuration content
get_nanorc_content() {
    cat <<'EOF'
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
}

# MC ini configuration content
get_mc_ini_content() {
    cat <<'EOF'
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
}

# MC panels configuration content
get_mc_panels_content() {
    cat <<'EOF'
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
}

# iftop configuration content
get_iftoprc_content() {
    cat <<'EOF'
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
}

# htop configuration content
get_htoprc_content() {
    cat <<'EOF'
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
}

# Bash aliases content
get_bash_aliases_content() {
    cat <<'EOF'
# Custom bash aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias df='df -h'
alias du='du -h'
alias free='free -h'

# Pretty print log file interpreting ANSI control codes and create line breaks on ^M
alias catlog='_catlog() { cat "$1" | tr '\''\r'\'' '\''\n'\'' | less -R; }; _catlog'
EOF
}

# Top configuration content
get_toprc_content() {
    cat <<'EOF'
top's Config File (Linux processes with windows)
Id:k, Mode_altscr=0, Mode_irixps=1, Delay_time=2.0, Curwin=0
Def     fieldscur=  75  107   81  103  105  119  163  123  121  129  161  159  136  111  223  117  115  220   76   78
                    82   84   86   88   90   92   94   96   98  100  108  112  124  126  130  132  206  210  134  208
                   212  140  142  146  148  150  152  154  164  166  168  170  172  174  176  178  180  182  184  194
                   188  139  187  144  157  190  192  196  198  200  202  204  214  216  218  224  226  228  230  232
                   234  236  238  240  242  244  246  248  250  252  254  256  258  260  262  264  266  268  270  272
        winflags=671540, sortindx=18, maxtasks=0, graph_cpus=0, graph_mems=0, double_up=0, combine_cpus=0, core_types=0
        summclr=6, msgsclr=1, headclr=4, taskclr=4
Job     fieldscur=  75   77  115  111  117   80  103  105  137  119  123  128  120   79  139   82   84   86   88   90
                    92   94   96   98  100  106  108  112  124  126  130  132  134  140  142  144  146  148  150  152
                   154  156  158  160  162  164  166  168  170  172  174  176  178  180  182  184  186  188  190  192
                   194  196  198  200  202  204  206  208  210  212  214  216  218  220  222  224  226  228  230  232
                   234  236  238  240  242  244  246  248  250  252  254  256  258  260  262  264  266  268  270  272
        winflags=193844, sortindx=0, maxtasks=0, graph_cpus=0, graph_mems=0, double_up=0, combine_cpus=0, core_types=0
        summclr=6, msgsclr=6, headclr=7, taskclr=6
Mem     fieldscur=  75  117  119  120  123  125  127  129  131  154  132  156  135  136  102  104  111  139   76   78
                    80   82   84   86   88   90   92   94   96   98  100  106  108  112  114  140  142  144  146  148
                   150  152  158  160  162  164  166  168  170  172  174  176  178  180  182  184  186  188  190  192
                   194  196  198  200  202  204  206  208  210  212  214  216  218  220  222  224  226  228  230  232
                   234  236  238  240  242  244  246  248  250  252  254  256  258  260  262  264  266  268  270  272
        winflags=193844, sortindx=21, maxtasks=0, graph_cpus=0, graph_mems=0, double_up=0, combine_cpus=0, core_types=0
        summclr=5, msgsclr=5, headclr=4, taskclr=5
Usr     fieldscur=  75   77   79   81   85   97  115  111  117  137  139   82   86   88   90   92   94   98  100  102
                   104  106  108  112  118  120  122  124  126  128  130  132  134  140  142  144  146  148  150  152
                   154  156  158  160  162  164  166  168  170  172  174  176  178  180  182  184  186  188  190  192
                   194  196  198  200  202  204  206  208  210  212  214  216  218  220  222  224  226  228  230  232
                   234  236  238  240  242  244  246  248  250  252  254  256  258  260  262  264  266  268  270  272
        winflags=193844, sortindx=3, maxtasks=0, graph_cpus=0, graph_mems=0, double_up=0, combine_cpus=0, core_types=0
        summclr=3, msgsclr=3, headclr=2, taskclr=3
Fixed_widest=0, Summ_mscale=1, Task_mscale=1, Zero_suppress=0, Tics_scaled=0
EOF
}

# Configure nano for a user/directory
configure_nano() {
    local target_dir="$1"
    local nanorc="${target_dir}/.nanorc"
    
    get_nanorc_content > "$nanorc"
    chmod 644 "$nanorc"
}

# Configure Midnight Commander for a user/directory
configure_mc() {
    local target_dir="$1"
    local mc_dir="${target_dir}/.config/mc"
    
    mkdir -p "$mc_dir"
    get_mc_ini_content > "${mc_dir}/ini"
    get_mc_panels_content > "${mc_dir}/panels.ini"
    chmod -R 755 "$mc_dir"
}

# Configure iftop for a user/directory
configure_iftop() {
    local target_dir="$1"
    local iftoprc="${target_dir}/.iftoprc"
    
    get_iftoprc_content > "$iftoprc"
    chmod 644 "$iftoprc"
}

# Configure htop for a user/directory
configure_htop() {
    local target_dir="$1"
    local htop_dir="${target_dir}/.config/htop"
    
    mkdir -p "$htop_dir"
    get_htoprc_content > "${htop_dir}/htoprc"
    chmod -R 755 "$htop_dir"
}

# Configure top for a user/directory
configure_top() {
    local target_dir="$1"
    local top_dir="${target_dir}/.config/procps"
    
    mkdir -p "$top_dir"
    get_toprc_content > "${top_dir}/toprc"
    chmod -R 755 "$top_dir"
}

# Configure bash aliases for a user/directory
configure_bash_aliases() {
    local target_dir="$1"
    local bash_aliases="${target_dir}/.bash_aliases"
    local bashrc="${target_dir}/.bashrc"
    local profile="${target_dir}/.profile"
    
    get_bash_aliases_content > "$bash_aliases"
    chmod 644 "$bash_aliases"
    
    # Ensure .bashrc sources .bash_aliases if it exists
    if [ -f "$bashrc" ]; then
        # Check if .bash_aliases is already sourced
        if ! grep -q "\.bash_aliases" "$bashrc"; then
            cat >> "$bashrc" <<'BASHRC_EOF'

# Source bash aliases if available
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi
BASHRC_EOF
        fi
    else
        # Create minimal .bashrc if it doesn't exist
        cat > "$bashrc" <<'BASHRC_EOF'
# Source bash aliases if available
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi
BASHRC_EOF
        chmod 644 "$bashrc"
    fi

    # Ensure login shells source .bashrc (Debian usually does, but some images don't)
    if [ -f "$profile" ]; then
        if ! grep -q "\.bashrc" "$profile"; then
            cat >> "$profile" <<'PROFILE_EOF'

# Load interactive bash configuration for login shells
if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
PROFILE_EOF
        fi
    else
        cat > "$profile" <<'PROFILE_EOF'
# Load interactive bash configuration for login shells
if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
PROFILE_EOF
        chmod 644 "$profile"
    fi
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
    
    configure_nano "$target_home"
    configure_mc "$target_home"
    configure_iftop "$target_home"
    configure_htop "$target_home"
    configure_top "$target_home"
    configure_bash_aliases "$target_home"
    
    # Set ownership for user configs
    if [ "$target_user" != "skel" ]; then
        chown -R "${target_user}:${target_user}" "$target_home/.nanorc" \
            "$target_home/.config" "$target_home/.iftoprc" \
            "$target_home/.bash_aliases" "$target_home/.profile" 2>/dev/null || true
    fi
    
    log_success "User ${target_user} configuration complete"
}

# Configure default skeleton for new users
configure_skel() {
    log_step "Configuring /etc/skel for new users"
    
    local skel_dir="/etc/skel"
    
    # Use the same configuration functions
    configure_nano "$skel_dir"
    configure_mc "$skel_dir"
    configure_iftop "$skel_dir"
    configure_htop "$skel_dir"
    configure_top "$skel_dir"
    configure_bash_aliases "$skel_dir"
    
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
