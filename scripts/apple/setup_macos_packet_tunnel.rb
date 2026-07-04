#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'

project_path = File.expand_path('../../macos/Runner.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

runner = project.targets.find { |target| target.name == 'Runner' }
abort 'Runner target not found' unless runner

app_info = project.files.find { |file| file.display_name == 'AppInfo.xcconfig' }
abort 'AppInfo.xcconfig not found' unless app_info

project.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
end

target = project.targets.find { |candidate| candidate.name == 'ZeonPacketTunnel' }
target ||= project.new_target(:app_extension, 'ZeonPacketTunnel', :osx, '10.15')

target.build_configurations.each do |config|
  config.base_configuration_reference = app_info
  settings = config.build_settings
  settings['ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES'] = 'YES'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'ZeonPacketTunnel/ZeonPacketTunnel.entitlements'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = '$(MACOS_DEVELOPMENT_TEAM)'
  settings['INFOPLIST_FILE'] = 'ZeonPacketTunnel/Info.plist'
  settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks', '@executable_path/../../../../Frameworks']
  settings['MACOSX_DEPLOYMENT_TARGET'] = '10.15'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = '$(MACOS_BUNDLE_IDENTIFIER).ZeonPacketTunnel'
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['SKIP_INSTALL'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
end

def ensure_group(project, path)
  group = project.main_group
  path.split('/').each do |part|
    group = group.groups.find { |child| child.display_name == part } || group.new_group(part, part)
  end
  group
end

def ensure_file(group, path)
  group.files.find { |file| file.path == File.basename(path) || file.path == path } ||
    group.new_file(path)
end

def add_file_reference_once(target, ref)
  return if target.source_build_phase&.files_references&.include?(ref)

  target.add_file_references([ref])
end

def add_framework_once(target, ref)
  return if target.frameworks_build_phase.files_references.include?(ref)

  target.frameworks_build_phase.add_file_reference(ref, true)
end

shared_group = ensure_group(project, 'Shared')
runner_handlers_group = ensure_group(project, 'Runner/Handlers')
runner_vpn_group = ensure_group(project, 'Runner/VPN')
runner_vpn_helpers_group = ensure_group(project, 'Runner/VPN/Helpers')
runner_extensions_group = ensure_group(project, 'Runner/Extensions')
packet_group = ensure_group(project, 'ZeonPacketTunnel')
packet_singbox_group = ensure_group(project, 'ZeonPacketTunnel/SingBox')
frameworks_group = ensure_group(project, 'Frameworks')

runner_sources = {
  shared_group => ['FilePath.swift'],
  runner_extensions_group => ['Bundle+Properties.swift'],
  runner_handlers_group => %w[
    MethodHandler.swift
    StatusEventHandler.swift
    AlertsEventHandler.swift
    PlatformMethodHandler.swift
    FileMethodHandler.swift
  ],
  runner_vpn_group => %w[VPNManager.swift VPNConfig.swift],
  runner_vpn_helpers_group => ['Stored.swift']
}

runner_sources.each do |group, files|
  files.each do |file|
    ref = ensure_file(group, file)
    add_file_reference_once(runner, ref)
  end
end

packet_sources = {
  shared_group => ['FilePath.swift'],
  packet_group => ['PacketTunnelProvider.swift'],
  packet_singbox_group => %w[
    Extension+RunBlocking.swift
    ExtensionPlatformInterface.swift
    ExtensionProvider.swift
  ]
}

packet_sources.each do |group, files|
  files.each do |file|
    ref = ensure_file(group, file)
    add_file_reference_once(target, ref)
  end
end

ensure_file(packet_group, 'Info.plist')
ensure_file(packet_group, 'ZeonPacketTunnel.entitlements')

framework_ref =
  frameworks_group.files.find { |file| file.path == '../hiddify-core/bin/HiddifyCore.xcframework' } ||
  frameworks_group.new_file('../hiddify-core/bin/HiddifyCore.xcframework')

[runner, target].each do |native_target|
  add_framework_once(native_target, framework_ref)
end

runner.add_dependency(target) unless runner.dependencies.any? { |dependency| dependency.target == target }

embed_phase = runner.copy_files_build_phases.find { |phase| phase.display_name == 'Embed App Extensions' }
embed_phase ||= runner.new_copy_files_build_phase('Embed App Extensions')
embed_phase.dst_subfolder_spec = '13'
embed_phase.add_file_reference(target.product_reference, true)

project.save
