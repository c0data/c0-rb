Gem::Specification.new do |spec|
  spec.name        = "c0"
  spec.version     = "0.1.0"
  spec.summary     = "C0DATA — structured data using ASCII C0 control codes"
  spec.description  = "A thin, fast Ruby binding over the c0 C core. The read " \
                      "path is zero-copy; the scan-heavy work runs as native C."
  spec.authors     = ["Thomas Sawyer"]
  spec.email       = ["transfire@gmail.com"]
  spec.homepage    = "https://github.com/c0data/c0-rb"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*.rb", "ext/c0/*.{c,rb}", "c0-c/c0.h", "README.md", "LICENSE"]
  spec.extensions   = ["ext/c0/extconf.rb"]
  spec.require_paths = ["lib"]
end
