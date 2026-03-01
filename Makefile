SHELL := /bin/bash
.SHELLFLAGS := -euxo pipefail -c
.ONESHELL:
.SILENT:
.DEFAULT_GOAL := help

.FORCE:

.PHONY: .FORCE

# -----------------------------------------------------------------------------
# tooling/runtime domain
# -----------------------------------------------------------------------------
FLOX ?= flox
.flox.activate.cmd ?= $(FLOX) activate --
.tart.home ?= $(CURDIR)/.tart
.packer.cmd ?= $(.flox.activate.cmd) packer
.tart.cmd ?= $(.flox.activate.cmd) tart
export TART_HOME := $(.tart.home)

define .packer.run
$(.packer.cmd) $(1)
endef

define .tart.run
$(.tart.cmd) $(1)
endef

.tart.base.ref ?= ghcr.io/cirruslabs/macos-tahoe-vanilla:latest
.tart.clone.force ?= 0

# -----------------------------------------------------------------------------
# disk command snippets (shared shell fragments)
# -----------------------------------------------------------------------------
.tart.disk.cmd.ensure-parent = mkdir -p "$(dir $1)"
.tart.disk.cmd.prepare-image = if [[ -f "$2" ]]; then : "Reusing existing $1 disk: $2"; else diskutil image create blank --format ASIF --size $3G --volumeName "$1" "$2"; fi
.tart.disk.cmd.show-info = : "$1: $2"; ls -lh "$2" 2>/dev/null || true

# -----------------------------------------------------------------------------
# build/identity domain
# -----------------------------------------------------------------------------
.template ?= templates/vanilla-tahoe.pkr.hcl
.tart.vm-name ?= nxmatic-macos
.env.file ?= scripts/.envrc
.vm.scripts.dir ?= /private/tmp/scripts
.build.source ?= auto
.macos.ipsw ?= latest

define .build.source.effective
$(if $(filter auto,$(.build.source)),$(if $(wildcard $(.tart.home)/vms/$(.tart.vm-name)),clone,ipsw),$(.build.source))
endef

# Account identity defaults (Make-level knobs -> Packer vars -> script env)
.account.primary-name ?= admin
.account.primary-full-name ?= Stephane Lacoin (aka nxmatic)
.account.primary-alias ?= nxmatic
.data.home-user ?= $(.account.primary-name)

# -----------------------------------------------------------------------------
# disk model domain (role list, defaults, computed paths)
# -----------------------------------------------------------------------------

# Tart disk sizing defaults (GB)
.tart.disk.root.max-size-gb ?= 100
.tart.disk.user-data.max-size-gb ?= 160
.tart.disk.user-library.max-size-gb ?= 40
.tart.disk.git-store.max-size-gb ?= 24
.tart.disk.nix-store.max-size-gb ?= 180
.tart.disk.build-chains.max-size-gb ?= 64

# Tart initial in-VM APFS sizes (GB)
.tart.disk.user-data.initial-size-gb ?= 64
.tart.disk.user-library.initial-size-gb ?= 20
.tart.disk.git-store.initial-size-gb ?= 12
.tart.disk.nix-store.initial-size-gb ?= 90
.tart.disk.build-chains.initial-size-gb ?= 16

.tart.disk.roles := user-data user-library git-store nix-store build-chains

# Computed default disk paths (align with template defaults)
.tart.disk.user-data.image-path ?=
.tart.disk.user-library.image-path ?=
.tart.disk.git-store.image-path ?=
.tart.disk.nix-store.image-path ?=
.tart.disk.build-chains.image-path ?=

define .tart.disk.image-path.effective
$(abspath $(if $(strip $($(1))),$($(1)),$(.tart.home)/disks/$(.tart.vm-name)/$(2).asif))
endef

define .tart.disk.define-effective
.tart.disk.$(1).image-path.effective := $(call .tart.disk.image-path.effective,.tart.disk.$(1).image-path,$(1))
endef

$(foreach role,$(.tart.disk.roles),$(eval $(call .tart.disk.define-effective,$(role))))

define .tart.disk.run-arg
--disk="$($(strip .tart.disk.$(1).image-path.effective)):sync=none"
endef

define .tart.run.disk.args
$(foreach role,$(.tart.disk.roles),$(call .tart.disk.run-arg,$(role)))
endef

# -----------------------------------------------------------------------------
# build behavior flags/toggles domain
# -----------------------------------------------------------------------------

# Optional toggles
.enable-boot-command ?= false
.attach-data-disk-during-build ?= true
.interactive ?= 1
.debug ?= 1

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

# -----------------------------------------------------------------------------
# packer CLI variable synthesis domain
# -----------------------------------------------------------------------------

define .tart.disk.packer.vars-for-role
$(call .tart.disk.packer.image-var,$(1))
$(call .tart.disk.packer.initial-var,$(1))
$(call .tart.disk.packer.max-var,$(1))
endef

define .tart.disk.packer.initial-prefix
$(if $(filter user-data,$(1)),user_data,$(subst -,_,$(1)))
endef

define .tart.disk.packer.common-prefix
$(if $(filter user-data,$(1)),data,$(subst -,_,$(1)))
endef

define .tart.disk.packer.image-var
-var $(call .tart.disk.packer.common-prefix,$(1))_disk_image_path=$(.tart.disk.$(1).image-path.effective)
endef

define .tart.disk.packer.initial-var
-var $(call .tart.disk.packer.initial-prefix,$(1))_disk_initial_size_gb=$(.tart.disk.$(1).initial-size-gb)
endef

define .tart.disk.packer.max-var
-var $(call .tart.disk.packer.common-prefix,$(1))_disk_max_size_gb=$(.tart.disk.$(1).max-size-gb)
endef

define .packer.vars
-var vm_name=$(.tart.vm-name)
-var vm_base_name=$(.tart.base.ref)
-var macos_build_source_mode=$(.build.source.effective)
-var macos_ipsw=$(.macos.ipsw)
-var tart_home=$(.tart.home)
-var macos_primary_account_name=$(.account.primary-name)
-var 'macos_primary_account_full_name=$(.account.primary-full-name)'
-var macos_primary_account_alias=$(.account.primary-alias)
-var macos_data_home_user=$(.data.home-user)
-var macos_vm_scripts_dir=$(.vm.scripts.dir)
-var root_disk_size_gb=$(.tart.disk.root.max-size-gb)
-var enable_boot_command=$(.enable-boot-command)
-var attach_data_disk_during_build=$(.attach-data-disk-during-build)
$(foreach role,$(.tart.disk.roles),$(call .tart.disk.packer.vars-for-role,$(role)))
endef

# -----------------------------------------------------------------------------
# env file synthesis domain
# -----------------------------------------------------------------------------

define .env.content
# Generated by make env. Edit Make variables, then regenerate.
set -a
$(.env.build)
$(.env.identity)
$(.env.disks)
set +a
endef

define .env.build
# Build/runtime configuration

MACOS_BUILD_SOURCE_MODE=$(.build.source.effective)
MACOS_IPSW=$(.macos.ipsw)
ENABLE_SAFARI_REMOTE_AUTOMATION=0
NIX_INSTALLER_URL=https://artifacts.nixos.org/nix-installer
NIX_INSTALLER_PATH=/private/tmp/nix-installer
NIX_INSTALL_AT_BUILD=0
NIX_INSTALL_ALLOW_UNMOUNTED_NIX=0

endef

define .env.identity
# Account identity for in-VM scripts (e.g. provisioning, dev setup)

PRIMARY_ACCOUNT_NAME=$(.account.primary-name)
PRIMARY_ACCOUNT_FULL_NAME="$(.account.primary-full-name)"
PRIMARY_ACCOUNT_ALIAS=$(.account.primary-alias)
DATA_HOME_USER=$(.data.home-user)

endef

define .env.disks
# Role disk paths and sizes for in-VM scripts

USER_DATA_DISK_INITIAL_SIZE_GB=$(.tart.disk.user-data.initial-size-gb)
USER_LIBRARY_DISK_INITIAL_SIZE_GB=$(.tart.disk.user-library.initial-size-gb)
GIT_STORE_DISK_INITIAL_SIZE_GB=$(.tart.disk.git-store.initial-size-gb)
NIX_STORE_DISK_INITIAL_SIZE_GB=$(.tart.disk.nix-store.initial-size-gb)
BUILD_CHAINS_DISK_INITIAL_SIZE_GB=$(.tart.disk.build-chains.initial-size-gb)
DATA_DISK_USER_DATA_NAME="User Data"
DATA_DISK_USER_LIBRARY_NAME="User Library"
DATA_DISK_GIT_STORE_NAME="Git Store"
DATA_DISK_NIX_STORE_NAME="Nix Store"
DATA_DISK_BUILD_CHAINS_NAME="Build Chains"
DATA_COPY_BUILD_CHAINS=1
GIT_STORE_CONFIGURE_SYSTEM_MOUNT=1
GIT_STORE_SYSTEM_MOUNT_POINT=/private/var/lib/git
NIX_STORE_CONFIGURE_SYSTEM_MOUNT=1
NIX_STORE_SYSTEM_MOUNT_POINT=/nix
NIX_STORE_CONFIGURE_SYNTHETIC=1
SYSTEM_CONTAINER_SIZE_GB=64

endef


# -----------------------------------------------------------------------------
# targets domain
# -----------------------------------------------------------------------------

.PHONY: help env validate validate-packer validate-tart clone-from-vanilla prepare-disks build run vm-info disks-info clean-disks shell-fmt shell-check fmt

env: $(.env.file) ## Generate .env with runtime vars for in-VM scripts

$(.env.file): .FORCE
	: "Generating $@ from Make variables $(file >$(@), $(.env.content))"

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
	printf "  make -n build .interactive=1 .debug=1\n"

validate: validate-packer validate-tart shell-check ## Run all validations (packer, tart, shell)

validate-packer: ## Validate the Packer template
	$(call .packer.run,validate $(strip $(.packer.vars)) $(.template))

validate-tart: ## Validate Tart CLI access
	$(call .tart.run,--version) >/dev/null
	$(call .tart.run,list) >/dev/null

clone-from-vanilla: validate-tart ## Clone Tahoe vanilla image into .tart.vm-name (set .tart.clone.force=1 to replace)
	if [[ "$(.tart.clone.force)" == "1" ]]; then
		if $(call .tart.run,get "$(.tart.vm-name)") >/dev/null 2>&1; then
			$(call .tart.run,delete "$(.tart.vm-name)")
		fi
	fi
	if $(call .tart.run,get "$(.tart.vm-name)") >/dev/null 2>&1; then
		: "VM $(.tart.vm-name) already exists; skipping clone (set .tart.clone.force=1 to replace)."
		: "Ensuring root disk size is $(.tart.disk.root.max-size-gb)G for existing VM $(.tart.vm-name)."
		$(call .tart.run,set --disk-size $(.tart.disk.root.max-size-gb) "$(.tart.vm-name)")
	else
		$(call .tart.run,clone "$(.tart.base.ref)" "$(.tart.vm-name)")
		: "Resizing cloned VM root disk to $(.tart.disk.root.max-size-gb)G."
		$(call .tart.run,set --disk-size $(.tart.disk.root.max-size-gb) "$(.tart.vm-name)")
	fi

prepare-disks: ## Create role disk images when enabled and missing
ifneq ($(call opt-enabled,.attach-data-disk-during-build),)
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.user-data.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.user-library.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.git-store.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.nix-store.image-path.effective))
	$(call .tart.disk.cmd.ensure-parent,$(.tart.disk.build-chains.image-path.effective))
	$(call .tart.disk.cmd.prepare-image,User Data,$(.tart.disk.user-data.image-path.effective),$(.tart.disk.user-data.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,User Library,$(.tart.disk.user-library.image-path.effective),$(.tart.disk.user-library.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Git Store,$(.tart.disk.git-store.image-path.effective),$(.tart.disk.git-store.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Nix Store,$(.tart.disk.nix-store.image-path.effective),$(.tart.disk.nix-store.max-size-gb))
	$(call .tart.disk.cmd.prepare-image,Build Chains,$(.tart.disk.build-chains.image-path.effective),$(.tart.disk.build-chains.max-size-gb))
else
	: "Role disk attachment disabled (.attach-data-disk-during-build=$(strip $(.attach-data-disk-during-build))); skipping image preparation."
endif

build: prepare-disks ## Build the vanilla Tahoe image
	$(call .packer.run,build $(.packer.flags.interactive) $(.packer.flags.failure) $(strip $(.packer.vars)) $(.template))

run: prepare-disks ## Run the built VM with all role disks attached
	$(call .tart.run,run $(.tart.vm-name) $(strip $(.tart.run.disk.args)))

vm-info: ## Show Tart VM details
	$(call .tart.run,list)
	$(call .tart.run,get $(.tart.vm-name))

disks-info: ## Show role disk files and sizes
	$(call .tart.disk.cmd.show-info,User Data,$(.tart.disk.user-data.image-path.effective))
	$(call .tart.disk.cmd.show-info,User Library,$(.tart.disk.user-library.image-path.effective))
	$(call .tart.disk.cmd.show-info,Git Store,$(.tart.disk.git-store.image-path.effective))
	$(call .tart.disk.cmd.show-info,Nix Store,$(.tart.disk.nix-store.image-path.effective))
	$(call .tart.disk.cmd.show-info,Build Chains,$(.tart.disk.build-chains.image-path.effective))

clean-disks: ## Remove role disk images (requires CONFIRM=1)
	if [[ "$(CONFIRM)" != "1" ]]; then
		: "Refusing to delete disk images. Re-run with: make clean-disks CONFIRM=1"
		exit 1
	fi
	rm -f $(.tart.disk.user-data.image-path.effective) $(.tart.disk.user-library.image-path.effective) $(.tart.disk.git-store.image-path.effective) $(.tart.disk.nix-store.image-path.effective) $(.tart.disk.build-chains.image-path.effective)
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
