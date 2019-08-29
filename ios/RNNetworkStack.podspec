
Pod::Spec.new do |s|
  s.homepage = "https://facebook.github.io/react-native/"
  s.name         = "RNNetworkStack"
  s.version      = "1.0.0"
  s.summary      = "RNNetworkStack"
  s.description  = <<-DESC
                  RNNetworkStack
                   DESC
  #s.homepage     = ""
  s.license      = "MIT"
  # s.license      = { :type => "MIT", :file => "FILE_LICENSE" }
  s.author             = { "author" => "author@domain.cn" }
  s.platform     = :ios, "7.0"
  s.source       = { :git => "https://github.com/author/RNNetworkStack.git", :tag => "master" }
  s.source_files  = "*.{h,m}"
  s.requires_arc = true


  s.dependency "React"
  #s.dependency "others"

end

  