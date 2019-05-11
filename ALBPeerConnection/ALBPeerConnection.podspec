Pod::Spec.new do |s|
  s.name         = "ALBPeerConnection"
  s.version      = "3.0.2"
  s.summary      = "Peer-Peer networking classes written (mostly) in Swift"
  s.homepage     = "https://github.com/AaronBratcher/ALBPeerConnection"


  s.license      = "MIT"
  s.author             = { "Aaron Bratcher" => "aaronbratcher1@gmail.com" }
  s.social_media_url   = "http://twitter.com/AaronLBratcher"

  s.osx.deployment_target = "10.12"
  s.ios.deployment_target = "10.0"

  s.source       		= { :git => "https://github.com/AaronBratcher/ALBPeerConnection.git", :tag => s.version }
  s.swift_version		= '5.0'
  s.ios.source_files  	= "ALBPeerConnection", "ALBPeerConnection/ALBPeerConnection/**/*.{h,m,swift}"
  s.osx.source_files  	= "ALBPeerConnection", "ALBPeerConnection/ALBPeerConnection/**/*.{h,m,swift}"
  
  s.dependency 'CocoaAsyncSocket'
end
