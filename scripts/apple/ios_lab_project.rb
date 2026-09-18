# Generates only a disposable test project. Product App IDs and signing stay owned
# by the existing application project. xcodeproj is provided by pinned CocoaPods.
require 'xcodeproj'
require 'fileutils'

root = File.expand_path('../..', __dir__)
work = ARGV.fetch(0)
project = Xcodeproj::Project.new(File.join(work, 'IosLab.xcodeproj'))
target = project.new_target(:ui_test_bundle, 'IosLab', :ios, '15.5')
%w[IosLabEvidence.swift IosLabTests.swift].each do |name|
  file = project.main_group.new_file(File.join(root, 'ios/LabTests', name))
  target.source_build_phase.add_file_reference(file)
end
target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = ENV.fetch('ZEON_LAB_RUNNER_BUNDLE_ID', 'invalid.zeon.lab.simulator')
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['CODE_SIGN_STYLE'] = 'Manual'
  settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
  settings['DEVELOPMENT_TEAM'] = ENV.fetch('ZEON_LAB_DEVELOPMENT_TEAM', '')
  settings['PROVISIONING_PROFILE_SPECIFIER'] = ENV.fetch('ZEON_LAB_RUNNER_PROFILE', '')
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(target)
scheme.save_as(project.path, 'IosLab', true)
