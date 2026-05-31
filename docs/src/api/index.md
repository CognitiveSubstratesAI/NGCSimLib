# API Reference

```@meta
CurrentModule = NGCSimLib
```

Auto-generated from inline docstrings. Symbols are grouped by layer.

## Abstract types

```@docs
AbstractValueNode
AbstractCompartmentLike
AbstractOp
AbstractComponent
AbstractContext
AbstractProcess
```

## Compartment

```@docs
Compartment
root
target
target!
targeted
setup!
set!
get_value
get_needed_keys
unwrap
wire!
```

## Operations

```@docs
Summation
Product
ast_kernel
operands
lower
```

## Component

```@docs
name
context_path
compartments
@ngc_component
@compilable
is_compilable_method
get_compilable_body
get_compilable_signature
compilable_methods
```

## GlobalState

```@docs
GlobalStateManager
make_key
add_compartment!
get_compartment
check_key
add_key!
from_global_key
from_local_key
set_state!
get_state
reset_global_state!
```

## Context

```@docs
Context
ContextObjectType
register_obj!
add_connection!
get_objects_by_type
get_components
get_processes
recompile!
post_init!
@context_aware
```

## ContextManager

```@docs
ContextManager
current_path
current_context
current_location
get_context
context_exists
step!
step_back!
step_to!
register_context!
register_context_local!
remove_context!
clear_contexts!
join_path
split_path
append_path
```

## Process

```@docs
CompiledRunner
watch_list
keyword_order
is_compiled
watch!
pack_keywords
pack_rows
run
compile_process!
compile_with_reactant!
view_compiled
MethodProcess
JointProcess
then!
```

## Parser

```@docs
CompiledMethod
parse_method
compile_object!
get_compiled
ContextTransformer
KwargsTransformer
transform_kwargs
```

## Support — Logger

```@docs
ngc_warn
ngc_info
ngc_debug
ngc_error
ngc_critical
add_logging_level
custom_log
init_logging
```

## Support — Priority

```@docs
priority!
get_priority
has_priority
```

## Support — Deprecators

```@docs
@deprecated
deprecate_args
is_deprecated
original_of
```

## Support — Config / IO / Modules / Help

```@docs
init_config
get_config
provide_namespace
make_safe_filename
make_unique_path
check_serializable
load_module
load_attribute
load_from_path
check_attributes
guides
render_guide
GuideKind
```
