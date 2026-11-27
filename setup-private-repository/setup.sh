#!/usr/bin/env bash

# APF-mod file.

set -euo pipefail

key="${PRIVATE_REPOSITORY_SSH_KEY:-}"
if [[ -z "$key" ]]; then
	echo '::error::Repository SSH deploy key is empty'
	exit 1
fi

if [[ "$PRIVATE_REPOSITORY_URL" =~ ^https://([a-zA-Z0-9.-]+)/([a-zA-Z0-9_./-]+)$ ]]; then
	host="${BASH_REMATCH[1]}"
	repository="${BASH_REMATCH[2]}"
elif [[ "$PRIVATE_REPOSITORY_URL" =~ ^git@([a-zA-Z0-9.-]+):([a-zA-Z0-9_./-]+)$ ]]; then
	host="${BASH_REMATCH[1]}"
	repository="${BASH_REMATCH[2]}"
elif [[ "$PRIVATE_REPOSITORY_URL" =~ ^ssh://git@([a-zA-Z0-9.-]+)/([a-zA-Z0-9_./-]+)$ ]]; then
	host="${BASH_REMATCH[1]}"
	repository="${BASH_REMATCH[2]}"
else
	echo '::error::Unsupported repository URL; use HTTPS or SSH with user git and the default port'
	exit 1
fi
repository="${repository%.git}"

if [[ "${PRIVATE_REPOSITORY_INSTALL_MISSING_DEPENDENCIES:-false}" == true ]]; then
	packages=()
	if ! command -v git > /dev/null; then
		packages+=(git)
	fi
	for command in ssh ssh-keygen ssh-keyscan; do
		if ! command -v "$command" > /dev/null; then
			packages+=(openssh-client)
			break
		fi
	done
	for command in mktemp tr cat; do
		if ! command -v "$command" > /dev/null; then
			packages+=(coreutils)
			break
		fi
	done
	if (( ${#packages[@]} )); then
		if ! command -v apt-get > /dev/null; then
			echo '::error::Installing dependencies requires apt-get'
			exit 1
		fi
		privilege=()
		if (( EUID != 0 )); then
			if ! command -v sudo > /dev/null; then
				echo '::error::Installing dependencies requires root or passwordless sudo'
				exit 1
			fi
			privilege=(sudo -n)
		fi
		"${privilege[@]}" apt-get update
		"${privilege[@]}" apt-get install -y --no-install-recommends "${packages[@]}"
	fi
fi

umask 077
repository_id="${host}-${repository//\//-}"
auth_dir=$(mktemp -d "$RUNNER_TEMP/private-repository.${repository_id}.XXXXXXXX")
alias="deploy-${auth_dir##*.}"
printf '%s\n' "$key" | tr -d '\r' > "$auth_dir/key"
unset key
ssh-keygen -y -P '' -f "$auth_dir/key" > /dev/null
ssh-keyscan -H "$host" > "$auth_dir/known_hosts"
test -s "$auth_dir/known_hosts"

# Each invocation gets its own alias and key; preserve all earlier invocations.
config="$RUNNER_TEMP/private-repositories-ssh-config"
cat >> "$config" <<EOF
Host $alias
  HostName $host
  User git
  IdentityFile "$auth_dir/key"
  IdentitiesOnly yes
  UserKnownHostsFile "$auth_dir/known_hosts"
  StrictHostKeyChecking yes

EOF
printf 'GIT_SSH_COMMAND=ssh -F "%s"\n' "$config" >> "$GITHUB_ENV"

target="git@$alias:$repository.git"
for source in "https://$host/$repository" "git@$host:$repository" "ssh://git@$host/$repository"; do
	git config --global --add "url.$target.insteadOf" "$source.git"
	git config --global --add "url.$target.insteadOf" "$source"
done
