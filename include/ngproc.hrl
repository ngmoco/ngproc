-define(NGPROC_NAMES, ngproc_names).

-record(reg, {name :: ngproc:name(),
              pid :: pid()}).
-record(rev, {key :: {pid(), ngproc:name()}}).
-record(mon, {pid :: pid(),
              ref :: reference()}).

-type ngproc_resolver() :: module().

