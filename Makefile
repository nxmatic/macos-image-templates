SHELL := /bin/bash
.SHELLFLAGS := -euxo pipefail -c
.ONESHELL:
.SILENT:
.DEFAULT_GOAL := help

# Tooling
FLOX ?= flox
.flox.activate.cmd ?= $(FLOX) activate --
.tart.home ?= $(CURDIR)/.tart
.packer.cmd ?= $(.flox.activate.cmd) packer
.tart.cmd ?= $(.flox.activate.cmd) tart
.env.file ?= .env

define .env.load
set -a
. "$(CURDIR)/$(.env.file)"
set +a
endef

define .packer.run
$(call .env.load)
$(.packer.cmd) $(1)
endef

define .tart.run
$(call .env.load)
$(.tart.cmd) $(1)
endef

.tart.base.ref ?= ghcr.io/cirruslabs/macos-tahoe-vanilla:latest
.tart.clone.force ?= 0

.tart.disk.cmd.ensure-parent = mkdir -p "$(dir $1)"
.tart.disk.cmd.prepare-image = if [[ -f "$2" ]]; then : "Reusing existing $1 disk: $2"; else diskutil image create blank --format ASIF --size $3G --volumeName "$1" "$2"; fi
.tart.disk.cmd.show-info = : "$1: $2"; ls -lh "$2" 2>/dev/null || true

# Split-friendly grouping convention (future include files):
# - mk/tooling.mk: .*.cmd, .*.env.*
# - mk/flags.mk:   .packer.flags.* and toggle helpers
# - mk/disks.mk:   .tart.disk.* defaults/paths
# - mk/targets.mk: help/validate/build/run and operational targets

# Build defaults
.template ?= templates/vanilla-tahoe.pkr.hcl
.tart.vm-name ?= nxmatic-macos

# Account identity defaults (Make-level knobs -> Packer vars -> script env)
.account.primary-name ?= admin
.account.primary-full-name ?= Stephane Lacoin (aka nxmatic)
.account.primary-alias ?= nxmatic
.data.home-user ?= $(.account.primary-name)

# Tart disk sizing defaults (GB)
.tart.disk.root.max-size-gb ?= 100
.tart.disk.user-data.max-size-gb ?= 160
.tart.disk.user-library.max-size-gb ?= 40
.tart.disk.git-bare-store.max-size-gb ?= 8
.tart.disk.git-worktree-store.max-size-gb ?= 9
.tart.disk.nix-store.max-size-gb ?= 180
.tart.disk.build-chains.max-size-gb ?= 64
.tart.disk.vm-images.max-size-gb ?= 512

# Tart initial in-VM APFS sizes (GB)
.tart.disk.user-data.initial-size-gb ?= 64
.tart.disk.user-library.initial-size-gb ?= 20
.tart.disk.git-bare-store.initial-size-gb ?= 4
.tart.disk.git-worktree-store.initial-size-gb ?= 6
.tart.disk.nix-store.initial-size-gb ?= 90
.tart.disk.build-chains.initial-size-gb ?= 16
.tart.disk.vm-images.initial-size-gb ?= 120

# Optional toggles
.enable-boot-command ?= false
.attach-data-disk-during-build ?= true
.interactive ?= 1
.debug ?= 1

# Tart run profile defaults (for interactive/recovery troubleshooting)
.tart.run.vnc ?= 1
.tart.run.recovery ?= 0
.tart.run.net-bridged ?= Wi-Fi
.tart.run.root-disk-opts ?=
.tart.run.disk.opts ?= sync=none
.tart.run.extra-args ?=

# Optional flag helper:
# enabled when variable is defined and not one of: false 0 no off (case-sensitive)
define opt-enabled
$(if $(filter undefined,$(origin $(1))),,$(if $(filter false 0 no off,$(strip $($(1)))),,1))
endef

ifneq ($(call opt-enabled,.interactive),)
.packer.flags.interactive := -debug
else
.packer.flags.interactive :=
endif

ifneq ($(call opt-enabled,.debug),)
ifneq ($(call opt-enabled,.interactive),)
.packer.flags.failure := -on-error=ask
else
.packer.flags.failure := -on-error=abort
endif
else
.packer.flags.failure :=
endif

# Computed default disk paths (align with template defaults)
.tart.disk.user-data.image-path ?=
.tart.disk.user-library.image-path ?=
.tart.disk.git-bare-store.image-path ?=
.tart.disk.git-worktree-store.image-path ?=
.tart.disk.nix-store.image-path ?=
.tart.disk.build-chains.image-path ?=
.tart.disk.vm-images.image-path ?=

.tart.disk.user-data.image-path.effective := $(if $(strip $(.tart.disk.user-data.image-path)),$(.tart.disk.user-data.image-path),$(.tart.home)/disks/$(.tart.vm-name)/user-data.asif)
.tart.disk.user-library.image-path.effective := $(if $(strip $(.tart.disk.user-library.image-path)),$(.tart.disk.user-library.image-path),$(.tart.home)/disks/$(.tart.vm-name)/user-library.asif)
.tart.disk.git-bare-store.image-path.effective := $(if $(strip $(.tart.disk.git-bare-store.image-path)),$(.tart.disk.git-bare-store.image-path),$(.tart.home)/disks/$(.tart.vm-name)/git-bare-store.asif)
.tart.disk.git-worktree-store.image-path.effective := $(if $(strip $(.tart.disk.git-worktree-store.image-path)),$(.tart.disk.git-worktree-store.image-path),$(.tart.home)/disks/$(.tart.vm-name)/git-worktree-store.asif)
.tart.disk.nix-store.image-path.effective := $(if $(strip $(.tart.disk.nix-store.image-path)),$(.tart.disk.nix-store.image-path),$(.tart.home)/disks/$(.tart.vm-name)/nix-store.asif)
.tart.disk.build-chains.image-path.effective := $(if $(strip $(.tart.disk.build-chains.image-path)),$(.tart.disk.build-chains.image-path),$(.tart.home)/disks/$(.tart.vm-name)/build-chains.asif)
.tart.disk.vm-images.image-path.effective := $(if $(strip $(.tart.disk.vm-images.image-path)),$(.tart.disk.vm-images.image-path),$(.tart.home)/disks/$(.tart.vm-name)/vm-images.asif)

.tart.run.disk.opts.suffix := $(if $(strip $(.tart.run.disk.opts)),:$(strip $(.tart.run.disk.opts)),)

define .packer.vars
-var vm_name=$(.tart.vm-name)
-var vm_base_name=$(.tart.base.ref)
-var tart_home=$(.tart.home)
-var macos_primary_account_name=$(.account.primary-name)
-var 'macos_primary_account_full_name=$(.account.primary-full-name)'
-var macos_primary_account_alias=$(.account.primary-alias)
-var macos_data_home_user=$(.data.home-user)
-var root_disk_size_gb=$(.tart.disk.root.max-size-gb)
-var user_data_disk_initial_size_gb=$(.tart.disk.user-data.initial-size-gb)
-var user_library_disk_initial_size_gb=$(.tart.disk.user-library.initial-size-gb)
-var git_bare_store_disk_initial_size_gb=$(.tart.disk.git-bare-store.initial-size-gb)
-var git_worktree_store_disk_initial_size_gb=$(.tart.disk.git-worktree-store.initial-size-gb)
-var nix_store_disk_initial_size_gb=$(.tart.disk.nix-store.initial-size-gb)
-var build_chains_disk_initial_size_gb=$(.tart.disk.build-chains.initial-size-gb)
-var vm_images_disk_initial_size_gb=$(.tart.disk.vm-images.initial-size-gb)
-var data_disk_max_size_gb=$(.tart.disk.user-data.max-size-gb)
-var user_library_disk_max_size_gb=$(.tart.disk.user-library.max-size-gb)
-var git_bare_store_disk_max_size_gb=$(.tart.disk.git-bare-store.max-size-gb)
-var git_worktree_store_disk_max_size_gb=$(.tart.disk.git-worktree-store.max-size-gb)
-var nix_store_disk_max_size_gb=$(.tart.disk.nix-store.max-size-gb)
-var build_chains_disk_max_size_gb=$(.tart.disk.build-chains.max-size-gb)
-var vm_images_disk_max_size_gb=$(.tart.disk.vm-images.max-size-gb)
-var enable_boot_command=$(.enable-boot-command)
-var attach_data_disk_during_build=$(.attach-data-disk-during-build)
-var data_disk_image_path=$(.tart.disk.user-data.image-path.effective)
-var user_library_disk_image_path=$(.tart.disk.user-library.image-path.effective)
-var git_bare_store_disk_image_path=$(.tart.disk.git-bare-store.image-path.effective)
-var git_worktree_store_disk_image_path=$(.tart.disk.git-worktree-store.image-path.effective)
-var nix_store_disk_image_path=$(.tart.disk.nix-store.image-path.effective)
-var build_chains_disk_image_path=$(.tart.disk.build-chains.image-path.effective)
-var vm_images_disk_image_path=$(.tart.disk.vm-images.image-path.effective)
endef

define .tart.run.disk.args
--disk="$(.tart.disk.user-data.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.user-library.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.git-bare-store.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.git-worktree-store.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.nix-store.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.build-chains.image-path.effective)$(.tart.run.disk.opts.suffix)"
--disk="$(.tart.disk.vm-images.image-path.effective)$(.tart.run.disk.opts.suffix)"
endef

define .tart.run.console.args
$(if $(call opt-enabled,.tart.run.vnc),--vnc-experimental,)
$(if $(call opt-enabled,.tart.run.recovery),--recovery,)
$(if $(strip $(.tart.run.net-bridged)),--net-bridged="$(.tart.run.net-bridged)",)
$(if $(strip $(.tart.run.root-disk-opts)),--root-disk-opts="$(.tart.run.root-disk-opts)",)
endef

.PHONY: help validate validate-packer validate-tart clone-from-vanilla prepare-disks build run run-console run-recovery-console vm-info disks-info clean-disks shell-fmt shell-check fmt

$(.env.file):
	: "Generating $@ from Make variables"
	printf '%s\n' '# Generated by Make. Edit Make variables instead.' 'TART_HOME=$(.tart.home)' > "$@"

help: ## Show available targets
	set +x
	awk 'BEGIN {FS = ":.*##"; printf "\nTargets:\n"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	printf "\nNote:\n"
	printf "  VM initialization is intentionally user-driven for now.\n"
	printf "  Default mode is interactive+debug (override with .interactive=0 and/or .debug=0).\n"
	printf "\nExamples:\n"
	printf "  make build .tart.vm-name=nxmatic-macos\n"
	printf "  make build .interactive=1\n"
	printf "  make build .debug=1\n"
	printf "  make build .interactive=1 .debug=1\n"
	printf "  make build .tart.disk.nix-store.max-size-gb=200 .tart.disk.user-library.initial-size-gb=24\n"
	printf "  make clone-from-vanilla .tart.vm-name=nxmatic-macos\n"
	printf "  make run-console .tart.vm-name=nikopol\n"
	printf "  make run-recovery-console .tart.vm-name=nikopol .tart.run.disk.opts=sync=none,caching=cached\n"
	printf "  make -n build .interactive=1 .debug=1\n"

validate: validate-packer validate-tart shell-check ## Run all validations (packer, tart, shell)

validate-packer: $(.env.file) ## Validate the Packer template
	$(call .packer.run,validate $(strip $(.packer.vars)) $(.template))

validate-tart: $(.env.file) ## Validate Tart CLI access
	$(call .tart.run,--version) >/dev/null
	$(call .tart.run,list) >/dev/null

clone-from-vanilla: validate-tart $(.env.file) ## Clone Tahoe vanilla image into .tart.vm-name (set .tart.clone.force=1 to replace)
	if [[ "$(.tart.clone.force)" == "1" ]]; then
		if $(call .tart.run,get "$(.tart.vm-name)") >/dev/null 2>&1; then
			$(call .tart.run,delete "$(.tart.vm-name)")
		fi
	fi
	if $(call .tart.run,get "$(.tart.vm-name)") >/dev/null 2>&1; then
		: "VM $(.tart.vm-name) already exists; skipping clone (set .tart.clone.force=1 to replace)."
	else
		$(call .tart.run,clone "$(.tart.base.ref)" "$(.tart.vm-name)")
	fi

prepare-disks: ## Create role disk images when enabled and missing
ifneq ($(call opt-enabled,.attach-data-disk-during-build),)
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.user-data.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.user-library.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.git-bare-store.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.git-worktree-store.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.nix-store.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.build-chains.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.vm-images.image-path.effective))
	$(call .tart.disk.cmd.prepare-image,User Data,$(.tart.disk.user-data.image-path.effective),$(.tart.disk.user-data.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,User Library,$(.tart.disk.user-library.image-path.effective),$(.tart.disk.user-library.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Git Bare Store,$(.tart.disk.git-bare-store.image-path.effective),$(.tart.disk.git-bare-store.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Git Worktree Store,$(.tart.disk.git-worktree-store.image-path.effective),$(.tart.disk.git-worktree-store.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Nix Store,$(.tart.disk.nix-store.image-path.effective),$(.tart.disk.nix-store.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Build Chains,$(.tart.disk.build-chains.image-path.effective),$(.tart.disk.build-chains.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,VM Images,$(.tart.disk.vm-images.image-path.effective),$(.tart.disk.vm-images.max-size-gb))
else
	: "Role disk attachment disabled (.attach-data-disk-during-build=$(strip $(.attach-data-disk-during-build))); skipping image preparation."
endif

build: prepare-disks $(.env.file) ## Build the vanilla Tahoe image
	$(call .packer.run,build $(.packer.flags.interactive) $(.packer.flags.failure) $(strip $(.packer.vars)) $(.template))

run: prepare-disks $(.env.file) ## Run the built VM with all role disks attached
	$(call .tart.run,run $(.tart.vm-name) $(strip $(.tart.run.disk.args)))

run-console: prepare-disks $(.env.file) ## Run VM with console troubleshooting defaults (VNC experimental + optional bridge/recovery)
	$(call .tart.run,run $(.tart.vm-name) $(strip $(.tart.run.console.args) $(.tart.run.disk.args) $(.tart.run.extra-args)))

run-recovery-console: .tart.run.recovery=1
run-recovery-console: run-console ## Run VM in recovery mode with console troubleshooting defaults

vm-info: $(.env.file) ## Show Tart VM details
	$(call .tart.run,list)
	$(call .tart.run,get $(.tart.vm-name))

disks-info: ## Show role disk files and sizes
	$(call .tart.disk.cmd.show-info,User Data,$(.tart.disk.user-data.image-path.effective))
	$(call .tart.disk.cmd.show-info,User Library,$(.tart.disk.user-library.image-path.effective))
	$(call .tart.disk.cmd.show-info,Git Bare Store,$(.tart.disk.git-bare-store.image-path.effective))
	$(call .tart.disk.cmd.show-info,Git Worktree Store,$(.tart.disk.git-worktree-store.image-path.effective))
	$(call .tart.disk.cmd.show-info,Nix Store,$(.tart.disk.nix-store.image-path.effective))
	$(call .tart.disk.cmd.show-info,Build Chains,$(.tart.disk.build-chains.image-path.effective))
	$(call .tart.disk.cmd.show-info,VM Images,$(.tart.disk.vm-images.image-path.effective))

clean-disks: ## Remove role disk images (requires CONFIRM=1)
	if [[ "$(CONFIRM)" != "1" ]]; then
		: "Refusing to delete disk images. Re-run with: make clean-disks CONFIRM=1"
		exit 1
	fi
	rm -f $(.tart.disk.user-data.image-path.effective) $(.tart.disk.user-library.image-path.effective) $(.tart.disk.git-bare-store.image-path.effective) $(.tart.disk.git-worktree-store.image-path.effective) $(.tart.disk.nix-store.image-path.effective) $(.tart.disk.build-chains.image-path.effective) $(.tart.disk.vm-images.image-path.effective)
	: "Removed role disk images for $(.tart.vm-name)."

shell-fmt: ## Format shell scripts if shfmt is available
	if command -v shfmt >/dev/null 2>&1; then
		shfmt -w scripts/*.sh
	else
		: "shfmt not found, skipping."
	fi

shell-check: ## Lint shell scripts if shellcheck is available
	if command -v shellcheck >/dev/null 2>&1; then
		shellcheck scripts/*.sh
	else
		: "shellcheck not found, skipping."
	fi

fmt: ## Alias for shell-fmt
	$(MAKE) shell-fmt
