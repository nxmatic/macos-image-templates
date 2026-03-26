packer {
  required_plugins {
    tart = {
      version = ">= 1.16.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "data_disk_max_size_gb" {
  type        = number
  default     = 160
  description = "Maximum logical size (GB) of the User Data disk image artifact created on the host during packer build."
  validation {
    condition     = var.data_disk_max_size_gb >= 1
    error_message = "Data disk max size must be greater than or equal to 1 GB."
  }
}

variable "user_library_disk_max_size_gb" {
  type        = number
  default     = 120
  description = "Maximum logical size (GB) for User Library disk image."
  validation {
    condition     = var.user_library_disk_max_size_gb >= 1
    error_message = "User Library disk max size must be greater than or equal to 1 GB."
  }
}

variable "git_store_disk_max_size_gb" {
  type        = number
  default     = 100
  description = "Maximum logical size (GB) for Git Store disk image."
  validation {
    condition     = var.git_store_disk_max_size_gb >= 1
    error_message = "Git Store disk max size must be greater than or equal to 1 GB."
  }
}

variable "nix_store_disk_max_size_gb" {
  type        = number
  default     = 100
  description = "Maximum logical size (GB) for Nix Store disk image."
  validation {
    condition     = var.nix_store_disk_max_size_gb >= 1
    error_message = "Nix Store disk max size must be greater than or equal to 1 GB."
  }
}

variable "build_chains_disk_max_size_gb" {
  type        = number
  default     = 64
  description = "Maximum logical size (GB) for Build Chains disk image."
  validation {
    condition     = var.build_chains_disk_max_size_gb >= 1
    error_message = "Build Chains disk max size must be greater than or equal to 1 GB."
  }
}

variable "vm_images_disk_max_size_gb" {
  type        = number
  default     = 512
  description = "Maximum logical size (GB) for VM Images disk image."
  validation {
    condition     = var.vm_images_disk_max_size_gb >= 1
    error_message = "VM Images disk max size must be greater than or equal to 1 GB."
  }
}

variable "user_data_disk_initial_size_gb" {
  type        = number
  default     = 64
  description = "Initial APFS volume size (GB) to use inside the User Data disk. Set to 0 to use maximum available size immediately."
  validation {
    condition     = var.user_data_disk_initial_size_gb >= 0
    error_message = "User Data disk initial size must be greater than or equal to 0 GB (0 means max available size)."
  }
}

variable "user_library_disk_initial_size_gb" {
  type        = number
  default     = 20
  description = "Initial APFS volume size (GB) to use inside the User Library disk. Set to 0 to use maximum available size immediately."
  validation {
    condition     = var.user_library_disk_initial_size_gb >= 0
    error_message = "User Library disk initial size must be greater than or equal to 0 GB (0 means max available size)."
  }
}

variable "git_store_disk_initial_size_gb" {
  type        = number
  default     = 12
  description = "Initial APFS volume size (GB) to use inside the Git Store disk. Set to 0 to use maximum available size immediately."
  validation {
    condition     = var.git_store_disk_initial_size_gb >= 0
    error_message = "Git Store disk initial size must be greater than or equal to 0 GB (0 means max available size)."
  }
}

variable "nix_store_disk_initial_size_gb" {
  type        = number
  default     = 90
  description = "Initial APFS volume size (GB) to use inside the Nix Store disk. Set to 0 to use maximum available size immediately."
  validation {
    condition     = var.nix_store_disk_initial_size_gb >= 0
    error_message = "Nix Store disk initial size must be greater than or equal to 0 GB (0 means max available size)."
  }
}

variable "build_chains_disk_initial_size_gb" {
  type        = number
  default     = 16
  description = "Initial APFS volume size (GB) to use inside the Build Chains disk. Set to 0 to use maximum available size immediately."
  validation {
    condition     = var.build_chains_disk_initial_size_gb >= 0
    error_message = "Build Chains disk initial size must be greater than or equal to 0 GB (0 means max available size)."
  }
}

variable "vm_images_disk_initial_size_gb" {
  type        = number
  default     = 120
  description = "Initial APFS volume size (GB) to use inside the VM Images disk. Set to 0 to use maximum available size immediately."
  validation {
    condition     = var.vm_images_disk_initial_size_gb >= 0
    error_message = "VM Images disk initial size must be greater than or equal to 0 GB (0 means max available size)."
  }
}

variable "data_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for User Data disk image path. If empty, defaults to ~/.tart/disks/<vm_name>/user-data.asif."
}

variable "user_library_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for User Library disk image path. If empty, defaults to ~/.tart/disks/<vm_name>/user-library.asif."
}

variable "git_store_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for Git Store disk image path. If empty, defaults to ~/.tart/disks/<vm_name>/git-store.asif."
}

variable "nix_store_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for Nix Store disk image path. If empty, defaults to ~/.tart/disks/<vm_name>/nix-store.asif."
}

variable "build_chains_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for Build Chains disk image path. If empty, defaults to ~/.tart/disks/<vm_name>/build-chains.asif."
}

variable "vm_images_disk_image_path" {
  type        = string
  default     = ""
  description = "Optional override for VM Images disk image path. If empty, defaults to ~/.tart/disks/<vm_name>/vm-images.asif."
}

variable "vm_name" {
  type        = string
  default     = "nxmatic-macos"
  description = "Name of the Tart VM to create."
}

variable "vm_base_name" {
  type        = string
  default     = "ghcr.io/cirruslabs/macos-tahoe-vanilla:latest"
  description = "Base Tart VM image to clone from (local VM name or registry reference)."
}

variable "macos_build_source_mode" {
  type        = string
  default     = "clone"
  description = "Source mode for VM creation: clone or ipsw."
  validation {
    condition     = contains(["clone", "ipsw"], var.macos_build_source_mode)
    error_message = "MacOS build source mode must be either clone or ipsw."
  }
}

variable "macos_ipsw" {
  type        = string
  default     = "latest"
  description = "IPSW source used when macos_build_source_mode=ipsw (URL/path/latest)."
}

variable "tart_home" {
  type        = string
  default     = ""
  description = "Optional Tart home directory. If empty, uses TART_HOME from environment, then ~/.tart."
}

variable "macos_primary_account_name" {
  type        = string
  default     = "admin"
  description = "Primary account short name used for post-install configuration."
}

variable "macos_primary_account_full_name" {
  type        = string
  default     = "Stephane Lacoin (aka nxmatic)"
  description = "Preferred full display name for the primary account."
}

variable "macos_primary_account_alias" {
  type        = string
  default     = "nxmatic"
  description = "Optional additional short-name alias to append to the primary account record."
}

variable "macos_data_home_user" {
  type        = string
  default     = "admin"
  description = "Preferred user for data-home replication. If unavailable, script fallback detection applies."
}

variable "macos_bootstrap_ssh_username" {
  type        = string
  default     = ""
  description = "Optional SSH username used by Packer communicator during bootstrap. If empty, defaults to macos_primary_account_name for ipsw builds and admin for clone builds."
}

variable "macos_vm_scripts_dir" {
  type        = string
  default     = "/private/tmp/scripts"
  description = "Directory inside VM from which provisioning scripts are executed. Override to run rsynced scripts from a custom /tmp path."
}

variable "macos_env_pointer_file" {
  type        = string
  default     = "/private/tmp/macos-image-template.envrc.path"
  description = "Path of file in VM that stores the runtime envrc filename (produced during provisioning)."
}

variable "nix_installer_url" {
  type        = string
  default     = "https://artifacts.nixos.org/nix-installer"
  description = "URL used to download the modern Nix installer script."
}

variable "nix_installer_path" {
  type        = string
  default     = "/private/tmp/nix-installer"
  description = "Path inside the VM where the Nix installer script is staged."
}

variable "nix_install_at_build" {
  type        = bool
  default     = true
  description = "Whether to run the modern Nix installer during packer build. Default true for fully provisioned images."
}

locals {
  use_ipsw                             = var.macos_build_source_mode == "ipsw"
  macos_bootstrap_ssh_username         = var.macos_bootstrap_ssh_username != "" ? var.macos_bootstrap_ssh_username : (local.use_ipsw ? var.macos_primary_account_name : "admin")
  effective_tart_home                  = var.tart_home != "" ? pathexpand(var.tart_home) : pathexpand("~/.tart")
  effective_data_disk_image_path         = var.data_disk_image_path != "" ? var.data_disk_image_path : "${local.effective_tart_home}/disks/${var.vm_name}/user-data.asif"
  effective_user_library_disk_image_path = var.user_library_disk_image_path != "" ? var.user_library_disk_image_path : "${local.effective_tart_home}/disks/${var.vm_name}/user-library.asif"
  effective_git_store_disk_image_path    = var.git_store_disk_image_path != "" ? var.git_store_disk_image_path : "${local.effective_tart_home}/disks/${var.vm_name}/git-store.asif"
  effective_nix_store_disk_image_path    = var.nix_store_disk_image_path != "" ? var.nix_store_disk_image_path : "${local.effective_tart_home}/disks/${var.vm_name}/nix-store.asif"
  effective_build_chains_disk_image_path = var.build_chains_disk_image_path != "" ? var.build_chains_disk_image_path : "${local.effective_tart_home}/disks/${var.vm_name}/build-chains.asif"
  effective_vm_images_disk_image_path    = var.vm_images_disk_image_path != "" ? var.vm_images_disk_image_path : "${local.effective_tart_home}/disks/${var.vm_name}/vm-images.asif"
}

variable "attach_data_disk_during_build" {
  type        = bool
  default     = true
  description = "Whether to attach the secondary data disk while packer is building."
}

variable "enable_boot_command" {
  type        = bool
  default     = false
  description = "Whether to run automated macOS setup keystrokes (boot_command). Set to false for manual VNC-driven setup."
}

variable "system_container_size_gb" {
  type        = number
  default     = 64
  description = "Target size (GB) for APFS system container disk0s2. Set to 0 to use maximum available size. Set to a positive value (e.g. 64) to leave free space on disk0."
  validation {
    condition     = var.system_container_size_gb >= 0
    error_message = "System container size must be greater than or equal to 0 GB (0 means max available size)."
  }
}

variable "root_disk_size_gb" {
  type        = number
  default     = 100
  description = "Root VM disk size (GB)."
  validation {
    condition     = var.root_disk_size_gb >= 50
    error_message = "Root disk size must be greater than or equal to 50 GB."
  }
}

variable "root_disk_format" {
  type        = string
  default     = "asif"
  description = "Root VM disk image format used by tart create (raw or asif)."
  validation {
    condition     = contains(["raw", "asif"], var.root_disk_format)
    error_message = "Root disk format must be either 'raw' or 'asif'."
  }
}

variable "recovery_partition_mode" {
  type        = string
  default     = "keep"
  description = "Recovery partition handling mode: keep, delete or relocate."
  validation {
    condition     = contains(["keep", "delete", "relocate"], var.recovery_partition_mode)
    error_message = "Recovery partition mode must be one of: keep, delete, or relocate."
  }
}

source "tart-cli" "tart" {
  vm_base_name = local.use_ipsw ? "" : var.vm_base_name
  from_ipsw    = local.use_ipsw ? var.macos_ipsw : ""
  vm_name      = var.vm_name
  cpu_count    = 7
  memory_gb    = 32
  display      = "1728x1080"
  disk_size_gb = var.root_disk_size_gb
  disk_format  = var.root_disk_format
  ssh_password = "admin"
  ssh_username = local.macos_bootstrap_ssh_username
  ssh_timeout  = "180s"
  boot_wait               = "5s"
  boot_key_interval       = "20ms"
  boot_keygroup_interval  = "80ms"
  run_extra_args = var.attach_data_disk_during_build ? [
    "--disk=${abspath(local.effective_data_disk_image_path)}:sync=none",
    "--disk=${abspath(local.effective_user_library_disk_image_path)}:sync=none",
    "--disk=${abspath(local.effective_git_store_disk_image_path)}:sync=none",
    "--disk=${abspath(local.effective_nix_store_disk_image_path)}:sync=none",
    "--disk=${abspath(local.effective_build_chains_disk_image_path)}:sync=none",
    "--disk=${abspath(local.effective_vm_images_disk_image_path)}:sync=none",
  ] : []
  boot_command = var.enable_boot_command ? [
    # hello, hola, bonjour, etc.
    "<wait40s><spacebar>",
    # Language: most of the times we have a list of "English"[1], "English (UK)", etc. with
    # "English" language already selected. If we type "english", it'll cause us to switch
    # to the "English (UK)", which is not what we want. To solve this, we switch to some other
    # language first, e.g. "Italiano" and then switch back to "English". We'll then jump to the
    # first entry in a list of "english"-prefixed items, which will be "English".
    #
    # [1]: should be named "English (US)", but oh well 🤷
    "<wait30s>italiano<esc>english<enter>",
    # Select Your Country or Region
    "<wait30s><click 'Select Your Country or Region'><wait5s>united states<leftShiftOn><tab><leftShiftOff><spacebar>",
    # Transfer Your Data to This Mac
    "<wait10s><tab><tab><tab><spacebar><tab><tab><spacebar>",
    # Written and Spoken Languages
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Accessibility
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Data & Privacy
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Create a Mac Account
    "<wait10s><tab><tab><tab><tab><tab><tab>Managed via Tart<tab>nxmatic<tab>admin<tab>admin<tab><tab><spacebar><tab><tab><spacebar>",
    # Enable Voice Over
    "<wait75s><leftAltOn><f5><leftAltOff>",
    # Sign In with Your Apple ID (primary + fallback keyboard paths)
    "<wait20s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait3s><tab><spacebar>",
    "<wait3s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Are you sure you want to skip signing in with an Apple ID?
    "<wait10s><tab><spacebar>",
    "<wait3s><enter>",
    # Terms and Conditions
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # I have read and agree to the macOS Software License Agreement
    "<wait10s><tab><spacebar>",
    # Disable Location Services
    "<wait10s><tab><spacebar>",
    # Confirm disabling Location Services
    "<wait10s><tab><spacebar>",
    # Select Your Time Zone
    "<wait10s><tab><tab><tab>Europe/Paris<enter><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Analytics
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Screen Time
    "<wait10s><tab><tab><spacebar>",
    # Siri
    "<wait10s><tab><spacebar><leftShiftOn><tab><leftShiftOff><spacebar>",
    # You Mac is Ready for FileVault
    "<wait10s><leftShiftOn><tab><tab><leftShiftOff><spacebar>",
    # Mac Data Will Not Be Securely Encrypted
    "<wait10s><tab><spacebar>",
    # Choose Your Look
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Update Mac Automatically
    "<wait10s><tab><tab><spacebar>",
    # Welcome to Mac
    "<wait30s><spacebar>",
    # Disable Voice Over
    "<wait10s><leftAltOn><f5><leftAltOff>",
    # Enable Keyboard navigation
    # This is so that we can navigate the System Settings app using the keyboard
    "<wait10s><leftAltOn><spacebar><leftAltOff>Terminal<wait10s><enter>",
    "<wait10s><wait5s>defaults write NSGlobalDomain AppleKeyboardUIMode -int 3<enter>",
    # Now that the installation is done, open "System Settings"
    # On Tahoe opening System Settings through Spotlight is not very reliable, sometimes opens System information
    "<wait10s>open '/System/Applications/System Settings.app'<enter>",
    # Navigate to "Sharing"
    "<wait10s><leftCtrlOn><f2><leftCtrlOff><right><right><right><down>Sharing<enter>",
    # Navigate to "Screen Sharing" and enable it
    "<wait10s><tab><tab><tab><tab><tab><spacebar>",
    # Navigate to "Remote Login" and enable it
    "<wait10s><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><spacebar>",
    # Quit System Settings
    "<wait10s><leftAltOn>q<leftAltOff>",
    # Keep Gatekeeper enabled. If a specific downloaded app is blocked,
    # clear its quarantine attribute instead of globally disabling assessments:
    #   sudo xattr -dr com.apple.quarantine /path/to/App.app
  ] : []

  // A (hopefully) temporary workaround for Virtualization.Framework's
  // installation process not fully finishing in a timely manner
  create_grace_time = "15s"

  // Keep the recovery partition, otherwise it's not possible to "softwareupdate"
  recovery_partition = var.recovery_partition_mode
}

build {
  sources = ["source.tart-cli.tart"]

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "mkdir -p /private/tmp",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "printf '%s\\n' 'admin' | sudo -S -p '' bash -c \"install -d -m 0750 /etc/sudoers.d && printf '%s\\n' '${local.macos_bootstrap_ssh_username} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-packer-nopasswd && chmod 0440 /etc/sudoers.d/99-packer-nopasswd\"",
      "sudo -n -l >/dev/null",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../scripts"
    destination = "/private/tmp"
  }

  provisioner "file" {
    source      = "${path.root}/../scripts/.envrc"
    destination = "/private/tmp/macos-image-template.envrc.upload"
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "staging='/private/tmp/macos-image-template.envrc.upload'",
      "runtime_envrc=\"$(mktemp /private/tmp/macos-image-template.envrc.XXXXXX)\"",
      "mv \"$staging\" \"$runtime_envrc\"",
      "chmod 0600 \"$runtime_envrc\"",
      "printf '%s\\n' \"$runtime_envrc\" > '${var.macos_env_pointer_file}'",
      "chmod 0600 '${var.macos_env_pointer_file}'",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../data/tart-guest-agent.plist"
    destination = "~/tart-guest-agent.plist"
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "sudo install -d -m 0755 /usr/local/sbin",
      "sudo install -m 0755 '${var.macos_vm_scripts_dir}/relax-user-permissions.sh' /usr/local/sbin/relax-user-permissions",
      "sudo install -m 0755 '${var.macos_vm_scripts_dir}/manage-cache-volumes.sh' /usr/local/sbin/manage-cache-volumes",
      "sudo install -m 0755 '${var.macos_vm_scripts_dir}/run-provision-sequence.sh' /usr/local/sbin/run-provision-sequence",
      "sudo install -m 0755 '${var.macos_vm_scripts_dir}/trim-vscode-vm-services.sh' /usr/local/sbin/trim-vscode-vm-services",
      "sudo install -m 0755 '${var.macos_vm_scripts_dir}/install-user-tart-sbin.sh' /usr/local/sbin/install-user-tart-sbin",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "env MACOS_ENV_FILE=\"$(cat '${var.macos_env_pointer_file}')\" bash -euxo pipefail '${var.macos_vm_scripts_dir}/provision-base-system.sh'",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "env MACOS_ENV_FILE=\"$(cat '${var.macos_env_pointer_file}')\" bash -euxo pipefail '${var.macos_vm_scripts_dir}/trim-vscode-vm-services.sh'",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "env MACOS_ENV_FILE=\"$(cat '${var.macos_env_pointer_file}')\" bash -euxo pipefail '${var.macos_vm_scripts_dir}/install-tart-guest-agent.sh'",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "env MACOS_ENV_FILE=\"$(cat '${var.macos_env_pointer_file}')\" bash -euxo pipefail '${var.macos_vm_scripts_dir}/setup-data-disk.sh'",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "env MACOS_ENV_FILE=\"$(cat '${var.macos_env_pointer_file}')\" NIX_INSTALLER_URL='${var.nix_installer_url}' NIX_INSTALLER_PATH='${var.nix_installer_path}' NIX_INSTALL_AT_BUILD='${var.nix_install_at_build}' bash -euxo pipefail '${var.macos_vm_scripts_dir}/install-nix-installer.sh'",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "env MACOS_ENV_FILE=\"$(cat '${var.macos_env_pointer_file}')\" bash -euxo pipefail '${var.macos_vm_scripts_dir}/resize-system-container.sh'",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "env MACOS_ENV_FILE=\"$(cat '${var.macos_env_pointer_file}')\" bash -euxo pipefail '${var.macos_vm_scripts_dir}/rename-primary-user-if-vanilla.sh'",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "env MACOS_ENV_FILE=\"$(cat '${var.macos_env_pointer_file}')\" bash -euxo pipefail '${var.macos_vm_scripts_dir}/ensure-secondary-admin-user.sh'",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "env MACOS_ENV_FILE=\"$(cat '${var.macos_env_pointer_file}')\" bash -euxo pipefail '${var.macos_vm_scripts_dir}/install-user-tart-sbin.sh'",
    ]
  }

  provisioner "shell-local" {
    inline = [
      // Ensure parent directory exists for all secondary data disk images.
      // Do NOT pre-create .asif with truncate; reuse existing images when present
      // and let Tart initialize/manage missing images.
      "if [ ${var.user_data_disk_initial_size_gb} -gt ${var.data_disk_max_size_gb} ]; then echo 'user_data_disk_initial_size_gb cannot be greater than data_disk_max_size_gb'; exit 1; fi",
      "if [ ${var.user_library_disk_initial_size_gb} -gt ${var.user_library_disk_max_size_gb} ]; then echo 'user_library_disk_initial_size_gb cannot be greater than user_library_disk_max_size_gb'; exit 1; fi",
      "if [ ${var.git_store_disk_initial_size_gb} -gt ${var.git_store_disk_max_size_gb} ]; then echo 'git_store_disk_initial_size_gb cannot be greater than git_store_disk_max_size_gb'; exit 1; fi",
      "if [ ${var.nix_store_disk_initial_size_gb} -gt ${var.nix_store_disk_max_size_gb} ]; then echo 'nix_store_disk_initial_size_gb cannot be greater than nix_store_disk_max_size_gb'; exit 1; fi",
      "if [ ${var.build_chains_disk_initial_size_gb} -gt ${var.build_chains_disk_max_size_gb} ]; then echo 'build_chains_disk_initial_size_gb cannot be greater than build_chains_disk_max_size_gb'; exit 1; fi",
      "if [ ${var.vm_images_disk_initial_size_gb} -gt ${var.vm_images_disk_max_size_gb} ]; then echo 'vm_images_disk_initial_size_gb cannot be greater than vm_images_disk_max_size_gb'; exit 1; fi",
      "mkdir -p \"$(dirname '${local.effective_data_disk_image_path}')\"",
      "mkdir -p \"$(dirname '${local.effective_user_library_disk_image_path}')\"",
      "mkdir -p \"$(dirname '${local.effective_git_store_disk_image_path}')\"",
      "mkdir -p \"$(dirname '${local.effective_nix_store_disk_image_path}')\"",
      "mkdir -p \"$(dirname '${local.effective_build_chains_disk_image_path}')\"",
      "mkdir -p \"$(dirname '${local.effective_vm_images_disk_image_path}')\"",
      "if [ -f \"${local.effective_data_disk_image_path}\" ]; then echo \"Reusing existing User Data disk image: ${local.effective_data_disk_image_path}\"; else diskutil image create blank --format ASIF --size ${var.data_disk_max_size_gb}G --volumeName 'User Data' \"${local.effective_data_disk_image_path}\"; fi",
      "if [ -f \"${local.effective_user_library_disk_image_path}\" ]; then echo \"Reusing existing User Library disk image: ${local.effective_user_library_disk_image_path}\"; else diskutil image create blank --format ASIF --size ${var.user_library_disk_max_size_gb}G --volumeName 'User Library' \"${local.effective_user_library_disk_image_path}\"; fi",
      "if [ -f \"${local.effective_git_store_disk_image_path}\" ]; then echo \"Reusing existing Git Store disk image: ${local.effective_git_store_disk_image_path}\"; else diskutil image create blank --format ASIF --size ${var.git_store_disk_max_size_gb}G --volumeName 'Git Store' \"${local.effective_git_store_disk_image_path}\"; fi",
      "if [ -f \"${local.effective_nix_store_disk_image_path}\" ]; then echo \"Reusing existing Nix Store disk image: ${local.effective_nix_store_disk_image_path}\"; else diskutil image create blank --format ASIF --size ${var.nix_store_disk_max_size_gb}G --volumeName 'Nix Store' \"${local.effective_nix_store_disk_image_path}\"; fi",
      "if [ -f \"${local.effective_build_chains_disk_image_path}\" ]; then echo \"Reusing existing Build Chains disk image: ${local.effective_build_chains_disk_image_path}\"; else diskutil image create blank --format ASIF --size ${var.build_chains_disk_max_size_gb}G --volumeName 'Build Chains' \"${local.effective_build_chains_disk_image_path}\"; fi",
      "if [ -f \"${local.effective_vm_images_disk_image_path}\" ]; then echo \"Reusing existing VM Images disk image: ${local.effective_vm_images_disk_image_path}\"; else diskutil image create blank --format ASIF --size ${var.vm_images_disk_max_size_gb}G --volumeName 'VM Images' \"${local.effective_vm_images_disk_image_path}\"; fi",
      "echo \"User Data disk max/initial: ${var.data_disk_max_size_gb}G/${var.user_data_disk_initial_size_gb}G\"",
      "echo \"User Library disk max/initial: ${var.user_library_disk_max_size_gb}G/${var.user_library_disk_initial_size_gb}G\"",
      "echo \"Git Store disk max/initial: ${var.git_store_disk_max_size_gb}G/${var.git_store_disk_initial_size_gb}G\"",
      "echo \"Nix Store disk max/initial: ${var.nix_store_disk_max_size_gb}G/${var.nix_store_disk_initial_size_gb}G\"",
      "echo \"Build Chains disk max/initial: ${var.build_chains_disk_max_size_gb}G/${var.build_chains_disk_initial_size_gb}G\"",
      "echo \"VM Images disk max/initial: ${var.vm_images_disk_max_size_gb}G/${var.vm_images_disk_initial_size_gb}G\"",
      "echo \"Attach at runtime:\"",
      "echo \"  tart run ${var.vm_name} --disk='${local.effective_data_disk_image_path}:sync=none' --disk='${local.effective_user_library_disk_image_path}:sync=none' --disk='${local.effective_git_store_disk_image_path}:sync=none' --disk='${local.effective_nix_store_disk_image_path}:sync=none' --disk='${local.effective_build_chains_disk_image_path}:sync=none' --disk='${local.effective_vm_images_disk_image_path}:sync=none'\"",
    ]
  }
}
