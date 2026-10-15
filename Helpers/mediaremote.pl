# Загружает libD10MediaRemote.dylib в системный perl и запускает поток событий.
# Аргумент: путь к dylib.
use strict;
use DynaLoader;
my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die "dl_load_file: " . DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($lib, "d10_stream") or die "dl_find_symbol: " . DynaLoader::dl_error();
my $xs = DynaLoader::dl_install_xsub("main::d10_stream", $sym);
&$xs();
