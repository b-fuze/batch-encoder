# Bash Config Parser
A config file syntax and parser written in Bash that attempts to mirror Bash syntax while supporting Bash variables, arrays, and dictionaries/associative arrays. Just like Bash, it doesn't support nesting of arrays and dictionaries, otherwise termed multidimensional arrays.

Valid syntax consists of: 
 - Bash words including:
   - Single quote strings
   - Double quote strings
   - Unquoted strings
   - Variable references. Yep, you read that right.
 - Scalar/array/dictionary variable assignments
 - Variable appending assignments
 - Comments

Bash commands, command substitions, and (temporarily) parameter expansions are invalid syntax and thus **syntax errors**.

### This does _not_ execute any Bash commands, as they are _syntax errors_.

## API & Usage
```sh
# Source/load the parser
source path/to/config/parser.sh

# Define the variables you want (with the proper types)
declare -A dict_config
array_config=()
string_config=

# Set up your variables for syncing with the parsed config
# This must be done _before_ parsing
bep_sync dict_config
bep_sync array_config
bep_sync string_config

# (Optionally) tell the parser where the file is. (Only used when reporting synax errors)
bep_cur_file=~/.config/my-app-config.sh

# And finally parse your config by piping it into `bep_parse`
bep_parse < "$bep_cur_file"

# Assuming the config file set a new value for `string_config` you
# should see it in effect here
echo "$string_config"
```

## FAQ
### Why did you make this?
I wanted a config file that supports Bash data types without the extra complexity of nested types and different primitive types that Bash doesn't support. I also wanted it to use Bash syntax without being able to run arbitrary code.

<!-- vim:set wrap: -->

