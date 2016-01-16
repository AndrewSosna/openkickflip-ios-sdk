Pod::Spec.new do |s|
  s.name         = "OpenKickflip"
  s.version      = "1.5"
  s.summary      = "The Open Kickflip platform provides a complete video broadcasting solution for your iOS 
application. Based on Chris' KickFlip."
  s.homepage     = "https://github.com/AndriiSosna-bMuse/openkickflip-ios-sdk"

  s.license      = 'Apache License, Version 2.0'

  s.author       = { "Daniel Pourhadi" => "", "Nicholas Phillips" => "nicholas.d.phillips@gmail.com", "Gaston Morixe" => "gaston@black.uy", "Chris Ballinger" => "chris@openwatch.net" }
  s.platform     = :ios, '8.0'
  s.source       = { :git => "https://github.com/AndriiSosna-bMuse/openkickflip-ios-sdk.git", :tag => s.version.to_s }

  s.source_files  = 'OpenKickflip', 'OpenKickflip/**/*.{h,m,mm,cpp}'
  s.resources = 'OpenKickflip/Resources/*'

  s.requires_arc = true

  s.libraries = 'c++'

  s.dependency 'AFNetworking', '~> 2.6'
  s.dependency 'AWSS3', '~> 2.3'
  s.dependency 'AFOAuth2Manager', '~> 2.0'
  s.dependency 'CocoaLumberjack', '~> 2.0'
  s.dependency 'SSKeychain', '~> 1.2'
  s.dependency 'FFmpegWrapper', '~> 1.0'
  s.dependency 'PureLayout', '~> 2.0'
  s.dependency 'Mantle', '~> 1.4'
  s.dependency 'SDWebImage', '~> 3.6'
  s.dependency 'FormatterKit/TimeIntervalFormatter', '~> 1.4'
end
