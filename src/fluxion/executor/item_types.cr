module Fluxion::Executor
  # What kind of thing a step's items are, and which package manager (if any)
  # installs them.
  #
  # Both are flat tables on purpose: any decomposition would only hide where a
  # kind's item type is decided, and this value is load-bearing well beyond the
  # executor. It is the discriminator persisted in the state file, the key
  # `ProbeRegistry` dispatches on, and half of `status`'s dedupe identity.
  #
  # Kept in a file named for the concept so that adding a step kind leads here
  # by grep rather than by memory.
  module ItemTypes
    extend self

    # ameba:disable Metrics/CyclomaticComplexity
    def for(step : Step) : ItemType
      case step
      when PackagesStep          then ItemType::Package
      when FlatpakStep           then ItemType::Flatpak
      when ToolPackagesStep      then ItemType::ToolPackage
      when SdkmanPackagesStep    then ItemType::SdkmanPackage
      when SystemUpdateStep      then ItemType::SystemUpdate
      when AptRepositoryStep     then ItemType::AptRepository
      when RpmRepositoryStep     then ItemType::RpmRepository
      when ZypperRepositoryStep  then ItemType::ZypperRepository
      when PacmanRepositoryStep  then ItemType::PacmanRepository
      when FlatpakRemoteStep     then ItemType::FlatpakRemote
      when GpgKeyStep            then ItemType::GpgKey
      when BinstallerProfileStep then ItemType::BinstallerProfile
      when NerdFontsStep         then ItemType::NerdFont
      when DotbotStep            then ItemType::Dotbot
      when ToolchainStep         then ItemType::Toolchain
      when OhMyZshStep           then ItemType::OhMyZsh
      when ShellScriptStep       then ItemType::ShellScript
      when ShellCommandStep      then ItemType::ShellCommand
      when ShellReloadStep       then ItemType::ShellReload
      when DefaultShellStep      then ItemType::DefaultShell
      when AssertStep            then ItemType::Assert
      when ManualStep            then ItemType::Manual
      when InterruptStep         then ItemType::Interrupt
      when UserGroupsStep        then ItemType::UserGroup
      when GitConfigStep         then ItemType::GitConfig
      when GitRepoStep           then ItemType::GitRepo
      when SystemdUnitStep       then ItemType::SystemdUnit
      when SystemSettingStep     then ItemType::SystemSetting
      when FileWriteStep         then ItemType::FileWrite
      else
        # Fail closed. Crystal cannot check a class-hierarchy `case` for
        # exhaustiveness, so this branch is the only thing standing between a
        # forgotten arm and a silently wrong answer. It used to return
        # `ShellCommand`, which meant a new step kind recorded its items under
        # the wrong discriminator: `state forget --type` could never find them,
        # `status` printed the wrong type, and probe selection picked the wrong
        # probe — with no compile error and no failing spec to say so.
        raise ExecutionError.new(
          "No ItemType mapped for step kind '#{step.kind}' (#{step.class}). " \
          "Add an arm to Executor::ItemTypes.for and a member to Fluxion::ItemType.")
      end
    end

    # Nil for the kinds where the concept does not apply, which is most of them.
    def package_manager_for(step : Step) : PackageManager?
      case step
      when PackagesStep     then step.package_manager
      when SystemUpdateStep then step.package_manager
      when FlatpakStep      then PackageManager::Flatpak
      end
    end
  end
end
