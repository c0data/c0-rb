require "mkmf"

# c0.h lives in the c0-c submodule at the repository root.
$INCFLAGS << " -I#{File.expand_path('../../c0-c', __dir__)}"

create_makefile("c0/c0_ext")
