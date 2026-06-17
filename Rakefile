require "rake/testtask"

file "ext/c0/Makefile" => "ext/c0/extconf.rb" do
  Dir.chdir("ext/c0") { ruby "extconf.rb" }
end

desc "Compile the C extension"
task compile: "ext/c0/Makefile" do
  Dir.chdir("ext/c0") { sh "make" }
end

Rake::TestTask.new(test: :compile) do |t|
  t.libs << "lib"
  t.test_files = FileList["test/*_test.rb"]
  t.warning = false
end

task default: :test
