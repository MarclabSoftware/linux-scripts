#!/usr/bin/env bash

# Provisioning module: small, consistent interactive Bash environment.
#
# Keeps login startup deterministic, loads the existing local-bin environment
# once, and adds completion, colors and fzf without replacing the host's
# distribution-provided .bashrc.
# Configuration and helpers are injected by init.sh.
# shellcheck disable=SC2154

renderBashProfile() {
    cat <<'EOF'
# Managed by linux-scripts. Local changes will be replaced.
[[ -r "${HOME}/.profile" ]] && . "${HOME}/.profile"
[[ -r "${HOME}/.bashrc" ]] && . "${HOME}/.bashrc"
EOF
}

renderProfile() {
    cat <<'EOF'
# Managed by linux-scripts. Local changes will be replaced.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) [ ! -d "${HOME}/.local/bin" ] || PATH="${HOME}/.local/bin:${PATH}" ;;
esac
[ ! -r "${HOME}/.local/bin/env" ] || . "${HOME}/.local/bin/env"
export PATH
EOF
}

renderInputrc() {
    cat <<'EOF'
# Managed by linux-scripts. Local changes will be replaced.
set completion-ignore-case on
set expand-tilde on
"\e[A": history-search-backward
"\e[B": history-search-forward
set colored-stats on
set visible-stats on
EOF
}

renderBashrcFragment() {
    cat <<'EOF'
# Managed by linux-scripts. Local changes will be replaced.
case $- in
    *i*) ;;
    *) return ;;
esac

if command -v dircolors >/dev/null 2>&1; then
    eval "$(dircolors -b)"
fi
alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

if ! declare -p BASH_COMPLETION_VERSINFO >/dev/null 2>&1; then
    if [[ -r /usr/share/bash-completion/bash_completion ]]; then
        . /usr/share/bash-completion/bash_completion
    elif [[ -r /etc/bash_completion ]]; then
        . /etc/bash_completion
    fi
fi

if command -v fzf >/dev/null 2>&1; then
    if fzf_bash="$(fzf --bash 2>/dev/null)"; then
        eval "${fzf_bash}"
        unset fzf_bash
    else
        if [[ -r /usr/share/fzf/key-bindings.bash ]]; then
            . /usr/share/fzf/key-bindings.bash
        elif [[ -r /usr/share/doc/fzf/examples/key-bindings.bash ]]; then
            . /usr/share/doc/fzf/examples/key-bindings.bash
        fi
        if [[ -r /usr/share/fzf/completion.bash ]]; then
            . /usr/share/fzf/completion.bash
        elif [[ -r /usr/share/doc/fzf/examples/completion.bash ]]; then
            . /usr/share/doc/fzf/examples/completion.bash
        fi
    fi
fi
EOF
}

ensureBashrcFragmentLoaded() {
    local bashrc="$1"
    local include_line=". \"\${HOME}/.config/linux-scripts/bashrc\""
    local temporary

    [[ "${bashrc}" == /* && ! -L "${bashrc}" && ! -d "${bashrc}" ]] || {
        printf 'Unsafe Bash startup file path: %s\n' "${bashrc}" >&2
        return 1
    }
    if [[ -e "${bashrc}" ]] &&
        grep -Fxq -- "${include_line}" "${bashrc}"; then
        return 0
    fi

    temporary="$(mktemp)" || return
    if [[ -e "${bashrc}" ]] && ! cat -- "${bashrc}" >"${temporary}"; then
        rm -f -- "${temporary}"
        return 1
    fi
    if ! printf '\n# Load the linux-scripts interactive shell fragment.\n%s\n' \
        "${include_line}" >>"${temporary}" ||
        ! installConfigFile "${bashrc}" <"${temporary}"; then
        rm -f -- "${temporary}"
        return 1
    fi
    rm -f -- "${temporary}"
}

configureShellHome() {
    local home_dir="$1"
    local owner="$2"
    local config_dir="${home_dir}/.config"
    local fragment_dir="${home_dir}/.config/linux-scripts"
    local content owner_group

    [[ "${home_dir}" == /* && -d "${home_dir}" && ! -L "${home_dir}" ]] || {
        printf 'Shell home must be an absolute real directory: %s\n' \
            "${home_dir}" >&2
        return 1
    }
    owner_group="$(id -gn -- "${owner}")" || return
    [[ ! -L "${config_dir}" ]] || {
        printf 'Symbolic-link shell configuration directory rejected: %s\n' \
            "${config_dir}" >&2
        return 1
    }
    if [[ ! -d "${config_dir}" ]]; then
        install -d -m 0755 -- "${config_dir}" || return
        chown -- "${owner}:${owner_group}" "${config_dir}" || return
    fi
    install -d -m 0755 -- "${fragment_dir}" || return
    content="$(renderBashProfile)" || return
    installConfigFile "${home_dir}/.bash_profile" <<<"${content}" || return
    content="$(renderProfile)" || return
    installConfigFile "${home_dir}/.profile" <<<"${content}" || return
    content="$(renderInputrc)" || return
    installConfigFile "${home_dir}/.inputrc" <<<"${content}" || return
    content="$(renderBashrcFragment)" || return
    installConfigFile "${fragment_dir}/bashrc" <<<"${content}" || return
    ensureBashrcFragmentLoaded "${home_dir}/.bashrc" || return
    chown -R -- "${owner}:${owner_group}" \
        "${home_dir}/.bash_profile" \
        "${home_dir}/.profile" \
        "${home_dir}/.inputrc" \
        "${fragment_dir}" || return
    chown -- "${owner}:${owner_group}" "${home_dir}/.bashrc"
}

configureShellEnvironment() {
    configureShellHome "${HOME_USER_D}" "${CONFIG_USER}" || return
    configureShellHome "${HOME_ROOT_D}" root || return
    printf 'Interactive Bash environment configured for %s and root\n' \
        "${CONFIG_USER}"
}
