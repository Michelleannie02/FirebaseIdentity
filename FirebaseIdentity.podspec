Pod::Spec.new do |s|
  s.name             = 'FirebaseIdentity'
  s.version          = '0.1.0'
  s.summary          = 'A short description of FirebaseIdentity.'
  s.description      = <<-DESC
TODO: Add long description of the pod here.
                       DESC
  s.homepage         = 'https://github.com/cgossain/FirebaseIdentity'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'cgossain' => 'cgossain@gmail.com' }
  s.source           = { :git => 'https://github.com/cgossain/FirebaseIdentity.git', :tag => s.version.to_s }
  s.swift_version = '4.2'
  s.static_framework = true
  s.ios.deployment_target = '10.3'
  s.source_files = 'FirebaseIdentity/Classes/**/*'
  s.dependency 'Firebase/Core'
  s.dependency 'Firebase/Auth'
end
