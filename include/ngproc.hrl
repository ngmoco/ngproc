-define(NGPROC_NAMES, ngproc_names).

-record(reg, {name :: ngproc:name(),
              pid :: pid(),
              ref :: 'undefined' | reference()}).
-record(ref, {r :: reference(),
              name :: ngproc:name()}).

