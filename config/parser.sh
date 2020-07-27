#!/bin/bash

# Batch Encoder config Parser

# Parser state
bep_cur_file=stdin # NOTE: Only used for printing errors
declare -i bep_cur_line=0
declare -i bep_cur_col=0
declare -i bep_cur_index=0

bep_cur_index_depth=()
declare -i bep_cur_depth=-1

# Temporary storage of current parameter/variable name name. Set
# by bep_param_name()
bep_cur_var_name=

# Temporary storage of currently processed value
bep_cur_scalar_value=
bep_cur_array_value=()
bep_cur_dict_subscript=

# Storage of scalar variables
declare -r bep_scalar_var_prefix="__bep_scalar_var_"
bep_scalar_vars_names=()

# Storage of array variables
declare -r bep_array_var_prefix="__bep_array_var_"
bep_array_vars_names=()

# Storage of dictionary variables
declare -r bep_dict_var_prefix="__bep_dict_var_"
bep_dict_vars_names=()

# Mapping of variable names to types
declare -A bep_var_types

# Enum of types
declare -r BEP_SCALAR_VAR=1
declare -r BEP_ARRAY_VAR=2
declare -r BEP_DICT_VAR=3
declare -r BEP_IFS=$'\x07'

# Source file (line delimited)
bep_src_lines=()
bep_src_raw=
declare -i bep_src_length=0
bep_src_line_char_accum=()

# API

# Parse function. Expects the parse target source to be piped into it.
bep_parse() {
    bep_src_raw=$(cat; echo e)
    bep_src_raw=${bep_src_raw:0:-1}
    declare -i bep_src_length=${#bep_src_raw}
    mapfile bep_src_lines <<< "$bep_src_raw"

    # Cache the offset of each line relative to the full blob 
    # to quickly determine the value of $bep_cur_index
    local -i char_accum=0
    for line in "${bep_src_lines[@]}"; do
        bep_src_line_char_accum+=($char_accum)
        (( char_accum += ${#line} ))
    done

    shopt -s extglob

    IFS=$BEP_IFS

    # Start parsing program node
    bep_program
}

# Syncs a global variable with the variables discovered when parsing.
# Takes the global variable name as its first parameter.
bep_sync() {
    local var_name=$1
    local var_type=$( (declare -p "$var_name") 2>&1 )

    case ${var_type:0:10} in
        'declare --' | 'declare -i' )
            declare -ng $bep_scalar_var_prefix$var_name=$var_name
            ;;
        'declare -a' )
            declare -ng $bep_array_var_prefix$var_name=$var_name
            ;;
        'declare -A' )
            declare -ng $bep_dict_var_prefix$var_name=$var_name
            ;;
        * )
            if [[ $var_type =~ not\ found ]]; then
                echo "config_parser: error: Variable '$var_name' must exist globally"
            elif [[ $var_type =~ -[aA]?r ]]; then
                echo "config_parser: error: Variable '$var_name' must not be readonly"
            fi

            exit 1
            ;;
    esac
}

# --------------------
# Utilities
# --------------------

bep_node_start() {
    bep_cur_index_depth+=($bep_cur_index)
    (( bep_cur_depth++ ))
}

bep_node_consume() {
    unset bep_cur_index_depth[-1]
    bep_cur_index_depth[-1]=$bep_cur_index
    (( bep_cur_depth-- ))
}

bep_node_recede() {
    bep_cur_index=${bep_cur_index_depth[-1]}
    unset bep_cur_index_depth[-1]
    (( bep_cur_depth-- ))
}

# Sync index to line/column
bep_node_index_sync_lc() {
    bep_cur_index=$(( ${bep_src_line_char_accum[$bep_cur_line]} + bep_cur_col ))
}

# Sync line/column to index
bep_node_lc_sync_index() {
    if (( ${bep_src_line_char_accum[$bep_cur_line]} < bep_cur_index )); then
        while (( bep_cur_line + 1 < ${#bep_src_lines[@]} && ${bep_src_line_char_accum[$(( bep_cur_line + 1 ))]} <= bep_cur_index )); do
            (( bep_cur_line++ ))
        done
    else
        while (( bep_cur_line - 1 >= 0 && ${bep_src_line_char_accum[$(( bep_cur_line ))]} > bep_cur_index )); do
            (( bep_cur_line-- ))
        done
    fi

    bep_cur_col=$(( bep_cur_index - ${bep_src_line_char_accum[$bep_cur_line]} ))
}

bep_get_line() {
    bep_node_lc_sync_index
    local -i line=${bep_src_lines[$bep_cur_line]}
    echo -n "$1=${line:$bep_cur_col}${BEP_IFS}_"
}

bep_get_char() {
    local cur_char=${bep_src_raw:$bep_cur_index:1}
    echo -n "$1=$cur_char${BEP_IFS}_"
}

bep_get_full_line() {
    bep_node_lc_sync_index
    echo -n "$1=${bep_src_lines[$bep_cur_line]}${BEP_IFS}_"
}

# Grep command
bep_grep() {
    local line=$( grep -z -P -m 1 -a -o "(?s)\A$1" <<< "${bep_src_raw:$bep_cur_index}" | tr -d '\0'; echo e )
    local line=${line:0:-1}
    echo -n "$2=$line${BEP_IFS}_"
}

bep_error() {
    echo "$1" 1>&2
}

bep_syntax_error() {
    bep_node_lc_sync_index
    echo -ne '\e[37m'"config_parser:\e[0m \e[31m""syntax error\e[0m \e[37m""in "
    echo -n "$bep_cur_file"
    echo -en "\e[0m:\e[92m$(( bep_cur_line + 1 ))\e[0m:\e[92m$(( bep_cur_col + 1 ))\e[0m:"
    echo " $1" 1>&2
}

bep_syntax_info() {
    bep_node_lc_sync_index
    echo -ne '\e[37m'"config_parser:\e[0m \e[33m""info:\e[0m \e[37m"
    echo -n "$bep_cur_file"
    echo -en "\e[0m:\e[92m$(( bep_cur_line + 1 ))\e[0m:\e[92m$(( bep_cur_col + 1 ))\e[0m:"
    echo " $1" 1>&2
}

# --------------------
# Parse nodes
# --------------------

# Top-most node
bep_program() {
    bep_node_start
    # root,ws,var,comment
    local last_token_type=root

    while (( bep_cur_index < bep_src_length )); do
        local $( bep_get_char cur_char )
        case $cur_char in
            ' ' | $'\t' | $'\n' )
                bep_whitespace
                last_token_type=ws
                ;;
            [a-zA-Z_] )
                bep_scalar_or_array_var_assignment || bep_dict_var_assignment && {
                    last_token_type=var
                } || {
                    bep_syntax_error "Commands aren't allowed in Bash configs"
                    exit 1
                }
                ;;
            '#' )
                bep_comment
                last_token_type=comment
                ;;
            * )
                bep_syntax_error "Unexpected token '$cur_char'"
                exit 1
        esac
    done

    bep_node_recede
}

# --- Creating/Assigning variables ---

# Scalar or array variable assignment. Includes
# appending assignment
bep_scalar_or_array_var_assignment() {
    bep_node_start
    local $( bep_grep '[a-zA-Z_][a-zA-Z0-9_]*\+?=' var_name )
    local var_type=$BEP_SCALAR_VAR
    local invalid_var
    bep_cur_scalar_value=
    bep_cur_array_value=()

    if [[ -n $var_name ]]; then
        (( bep_cur_index += ${#var_name} ))
        local var_name=${var_name:0:-1}
        local $( bep_get_char cur_char )
        local append_var

        # Check if is appending
        if [[ $var_name =~ \+$ ]]; then
            local var_name=${var_name:0:-1}
            local append_var=true
        fi

        declare -ng bep_scalar_array_var_node_cur_scalar_value=$bep_scalar_var_prefix$var_name

        if [[ -z $append_var ]]; then
            bep_scalar_array_var_node_cur_scalar_value=
        fi

        case $cur_char in
            ' ' | $'\t' )
                : # Skip here and handle at the end
                ;;
            $'\n' | ';' )
                (( bep_cur_index++ ))
                ;;
            '|' | ')' | '&' | '<' | '>' )
                bep_syntax_error "Unexpected token '$cur_char'"
                exit 1
                ;;
            '(' )
                # This is an array variable
                (( bep_cur_index++ ))
                local var_type=$BEP_ARRAY_VAR
                local $( bep_get_char cur_char )

                local -n array_var="$bep_array_var_prefix$var_name"
                if [[ -n $append_var ]]; then
                    array_var=("${array_var[@]}")
                else
                    array_var=()
                fi

                while [[ $cur_char != ')' ]]; do
                    case $cur_char in
                        $'\n' | $'\t' | ' ' )
                            bep_whitespace
                            local $( bep_get_char cur_char )
                            ;;
                        '(' | '|' | '&' | '<' | '>' | ';' )
                            bep_syntax_error "Unexpected token '$cur_char'"
                            exit 1
                            ;;
                        '#' )
                            bep_comment
                            local $( bep_get_char cur_char )
                            ;;
                        * )
                            bep_scalar_value true bep_cur_scalar_value
                            local $( bep_get_char cur_char )

                            array_var+=("$bep_cur_scalar_value")
                            bep_cur_scalar_value=
                    esac
                done

                (( bep_cur_index++ ))
                local $( bep_get_char cur_char )
                ;;
            * )
                bep_scalar_value true bep_cur_scalar_value
                local $( bep_get_char cur_char )

                case $cur_char in
                    '(' | ')' )
                        bep_syntax_error "Unexpected token '$cur_char'"
                        exit 1
                        ;;
                    '<' | '>' )
                        bep_syntax_info "Possible error at '$cur_char'"
                        local invalid_var='invalid '
                        ;;
                    ';' )
                        (( bep_cur_index++ ))
                        ;;
                esac
                ;;
        esac

        if [[ $cur_char =~ [$' \t'] ]]; then
            bep_single_line_whitespace
            local $( bep_get_char cur_char )

            case $cur_char in
                $'\n' | ';' )
                    # End of line/statement
                    (( bep_cur_index++ ))
                    ;;
                '#' )
                    bep_comment
                    ;;
                * )
                    # Invalid variable: env var for some kinda command
                    local invalid_var='invalid '
                    ;;
            esac
        fi

        # Save variable if it's not invalid
        if [[ -z $invalid_var ]]; then
            bep_var_types[$var_name]=$var_type

            if [[ $var_type == $BEP_SCALAR_VAR ]]; then
                bep_scalar_array_var_node_cur_scalar_value+=$bep_cur_scalar_value
            fi
        fi

        bep_node_consume
        return 0
    else
        bep_node_recede
        return 1
    fi
}

# Dictionary variable
# Includes appending assignment.
bep_dict_var_assignment() {
    bep_node_start
    local $( bep_grep '[a-zA-Z_][a-zA-Z0-9_]*\[' var_name )
    local invalid_var
    bep_cur_scalar_value=

    if [[ -n $var_name ]]; then
        (( bep_cur_index += ${#var_name} ))
        local var_name=${var_name:0:-1}
        local bep_dict_name=$bep_dict_var_prefix$var_name
        local append_var

        local -n dict_value=$bep_dict_name

        bep_dict_var_subscript || {
            bep_node_recede
            return 1
        }

        local $( bep_get_char cur_char )

        # Check if is appending
        if [[ $cur_char = '+' ]]; then
            local append_var=true
            (( bep_cur_index++ ))
            local $( bep_get_char cur_char )
            bep_cur_scalar_value=${dict_value[$bep_cur_dict_subscript]}
        fi

        if [[ $cur_char = '=' ]]; then
            (( bep_cur_index++ ))
            local $( bep_get_char cur_char )

            case $cur_char in
                ' ' | $'\t' )
                    # Empty dictionary var. Check if it's a valid variable.
                    bep_single_line_whitespace
                    local $( bep_get_char cur_char )

                    case $cur_char in
                        '#' )
                            bep_comment
                            ;;
                        ';' | $'\n' )
                            : # End of statement
                            ;;
                        '' )
                            # End of input
                            break
                            ;;
                        * )
                            local invalid_var=true
                            ;;
                    esac
                    ;;
                ';' | $'\n' )
                    # Empty dictionary var. Nothing to do.
                    (( bep_cur_index++ ))
                    ;;
                '(' )
                    bep_syntax_error "Unexpected token '('. Can't nest arrays in dictionaries"
                    exit 1
                    ;;
                * )
                    bep_scalar_value true bep_cur_scalar_value
                    local $( bep_get_char cur_char )

                    while true; do
                        case $cur_char in
                            ' ' | $'\t' )
                                bep_single_line_whitespace
                                local $( bep_get_char cur_char )
                                ;;
                            '#' )
                                bep_comment
                                break
                                ;;
                            ';' | $'\n' )
                                : # End of statement
                                break
                                ;;
                            '' )
                                # End of input
                                break
                                ;;
                            * )
                                local invalid_var=true
                                break
                                ;;
                        esac
                    done
            esac

            bep_var_types[$var_name]=$BEP_DICT_VAR
            dict_value[$bep_cur_dict_subscript]=$bep_cur_scalar_value
            bep_node_consume
            return 0
        else
            # Not a dict var assignment
            bep_node_recede
            return 1
        fi
    else
        # Not a dict var assignment
        bep_node_recede
        return 1
    fi
}

# Dictionary gets separate subscript node 'cuz its parsing
# rules make no sense
bep_dict_var_subscript() {
    bep_node_start
    local node_start_index=$bep_cur_index
    local bracket_depth=0
    bep_cur_dict_subscript=

    local $( bep_get_char cur_char )
    while [[ -n $cur_char ]]; do
        case $cur_char in
            '[' )
                bep_cur_dict_subscript+='['
                (( bracket_depth++ ))
                (( bep_cur_index++ ))
                local $( bep_get_char cur_char )
                ;;
            ']' )
                (( bep_cur_index++ ))

                if [[ $bracket_depth = 0 ]]; then
                    bep_node_consume
                    return 0
                fi

                bep_cur_dict_subscript+=']'
                (( bracket_depth-- ))
                local $( bep_get_char cur_char )
                ;;
            '*' | '@' )
                # Ensure a valid subscript
                local old_index=$bep_cur_index
                (( bep_cur_index++ ))

                if [[ $old_index = $node_start_index ]]; then
                    local $( bep_get_char next_char )
                    if [[ $next_char = ']' ]]; then
                        (( bep_cur_index-- ))
                        bep_syntax_error "singular '$cur_char' must be escaped with a backslash"
                        exit 1
                    fi
                fi

                local $( bep_get_char next_char )

                bep_cur_dict_subscript+=$cur_char
                local cur_char=$next_char
                ;;
            $'\n' | $'\t' | ' ' )
                # Whitespace is also part of the key in dict
                # subscripts
                local $( bep_grep '[ \t\n]+' whitespace )
                bep_cur_dict_subscript+=$whitespace
                (( bep_cur_index += ${#whitespace} ))
                local $( bep_get_char cur_char )
                ;;
            '`' )
                bep_syntax_error "Command substitution isn't supported"
                exit 1
                ;;
            \" )
                bep_double_quoted_string true bep_cur_dict_subscript || {
                    bep_syntax_error "Unterminated string in dictionary subscript"
                    exit 1
                }
                local $( bep_get_char cur_char )
                ;;
            \' )
                bep_single_quoted_string true bep_cur_dict_subscript || {
                    bep_syntax_error "Unterminated string in dictionary subscript"
                    exit 1
                }
                local $( bep_get_char cur_char )
                ;;
            \$ )
                bep_scalar_var_ref true bep_cur_dict_subscript || {
                    bep_cur_dict_subscript+='$'
                    (( bep_cur_index++ ))
                    local $( bep_get_char cur_char )
                }
                ;;
            * )
                local $( bep_grep '([^\[\]]|(?<=\\)[\[\]])+' subscript_value )
                (( bep_cur_index += ${#subscript_value} ))
                bep_cur_dict_subscript+=$( sed -zEe 's/\\(.)/\1/g' <<< "$subscript_value"; echo e )
                bep_cur_dict_subscript=${bep_cur_dict_subscript:0:-2}
                local $( bep_get_char cur_char )
                ;;
        esac
    done
}

# --- Scalar value ---
# AKA in Bash parlence as a "word"
bep_scalar_value() {
    bep_node_start
    local $( bep_get_char cur_char )
    local save_scalar=$1
    local save_target=$2
    local -n bep_cur_scalar_node_scalar_value=$save_target

    while [[ ! $cur_char =~ [$' \t\n|()&<>'] && -n $cur_char ]]; do
        case $cur_char in
            \" )
                bep_double_quoted_string $save_scalar $save_target || {
                    bep_syntax_error "Unterminated string"
                    exit 1
                }
                ;;
            \' )
                bep_single_quoted_string $save_scalar $save_target || {
                    bep_syntax_error "Unterminated string"
                    exit 1
                }
                ;;
            \` )
                bep_syntax_error "Backtick command substitution isn't supported"
                exit 1
                ;;
            $ )
                bep_scalar_var_ref $save_scalar $save_target || {
                    (( bep_cur_index++ ))
                    local $( bep_get_char cur_char )

                    case $cur_char in
                        '|' | ')' | '&' | '<' | '>' )
                            bep_syntax_error "Unexpected token '$cur_char'"
                            exit 1
                            ;;
                        '{' )
                            bep_syntax_error "Parameter expansion isn't supported"
                            exit 1
                            ;;
                        '(' )
                            bep_syntax_error "Command substitution isn't supported"
                            exit 1
                            ;;
                        '*' | '@' | '#' | '!' | '?' )
                            bep_syntax_info "Possible error: '\$$cur_char'"
                            (( bep_cur_index++ ))
                            local $( bep_get_char cur_char )
                            ;;
                        $'\n' | ';' )
                            bep_cur_scalar_node_scalar_value+='$'
                            (( bep_cur_index++ ))
                            ;;
                        ' ' | $'\t' )
                            break
                            ;;
                    esac
                }
                ;;
            $'\n' | ';' )
                # End of this scalar value
                break
                ;;
            * )
                bep_unquoted_string $save_scalar $save_target
                ;;
        esac

        local $( bep_get_char cur_char )
    done

    bep_node_consume
    return 0
}

# e.g:
#  - alphanum: 1337h4ck
#  - escapedquote: \' \" \`
#  - escapedspace: \ 
#  - escapeddollar: \ $
#  - combinedexample: \`\$1337\`\ \"h4x0rs\"
bep_unquoted_string() {
    bep_node_start
    local $( bep_grep '([^\\ \t\n;|&()<>$"'\''`]|\\[\\ \t\n;|&()<>$"'\''`])+' string )
    local $( bep_get_char cur_char )
    (( bep_cur_index += ${#string} ))
    bep_node_lc_sync_index
    bep_node_consume

    local save_target=$2
    if [[ -n $2 ]]; then
        local -n bep_cur_unquoted_str_node_scalar_value=$save_target
    fi

    if [[ -n $1 ]]; then
        local str_val
        mapfile -d '' str_val < <(sed -Ee 's/\\(.)/\1/g' <<< "$string")
        local str_val=${str_val[0]}
        bep_cur_unquoted_str_node_scalar_value+="${str_val:0:-1}"
    fi

    return 0
}

bep_double_quoted_string() {
    bep_node_start
    local save_scalar=$1
    local save_target=$2
    local scalar_value

    if [[ -n $2 ]]; then
        local -n bep_cur_dbl_quoted_str_node_scalar_value=$save_target
    fi

    # Skip first quote
    (( bep_cur_index++ ))

    while true; do
        local $( bep_grep '.*?((?<!\\)"|(?<!\$)(?<!\\)\$(?!\$)|(?<!\\)`)' string_start )
        local last_char=${string_start: -1}
        local string=$string_start

        case $last_char in
            \" )
                # This is a simple string without substitution, variable expansion
                # or anything. Take fast path.
                (( bep_cur_index += ${#string_start} ))

                if [[ -n $save_scalar ]]; then
                    local string=$( sed -Ee 's/\\"/"/g; s/(\$|\\)\$/$/g; s/\\`/`/g;' <<< "$string_start"; echo e )
                    bep_cur_dbl_quoted_str_node_scalar_value+="${string:0:-3}"
                fi

                bep_node_consume
                return 0
                ;;
            $ )
                local string=${string:0:-1}
                (( bep_cur_index += (${#string_start} - 1) ))

                if [[ -n $save_scalar ]]; then
                    local string=$( sed -Ee 's/\\"/"/g; s/(\$|\\)\$/$/g; s/\\`/`/g; s/\\\\/\\/g;' <<< "$string_start"; echo e )
                    bep_cur_dbl_quoted_str_node_scalar_value+="${string:0:-3}"
                fi

                bep_scalar_var_ref $save_scalar $save_target || {
                    bep_cur_dbl_quoted_str_node_scalar_value+='$'
                    (( bep_cur_index++ ))
                }
                ;;
            \` )
                bep_syntax_error "Backtick command substitution isn't supported"
                exit 1
                ;;
        esac
    done
}

bep_single_quoted_string() {
    bep_node_start
    local $( bep_grep "'.*?'" string )
    local save_target=$2
    local scalar_value

    if [[ -n $2 ]]; then
        local -n bep_cur_single_quoted_str_node_scalar_value=$save_target
    fi

    if [[ -n $string ]]; then
        (( bep_cur_index += ${#string} ))
        bep_node_consume
        local $( bep_get_char cur_char )

        if [[ -n $1 ]]; then
            bep_cur_single_quoted_str_node_scalar_value+="${string:1:-1}"
        fi

        return 0
    else
        bep_node_recede
        return 1
    fi
}

bep_scalar_var_ref() {
    bep_node_start
    local $( bep_grep '\$([0-9]|[a-zA-Z_][a-zA-Z0-9_]*)' var_name )
    local save_target=$2
    local bep_cur_var_ref_node_scalar_value

    if [[ -n $2 ]]; then
        local -n bep_cur_var_ref_node_scalar_value=$save_target
    fi

    if [[ -n $var_name ]]; then
        (( bep_cur_index += ${#var_name} ))
        local var_name=${var_name:1}

        if [[ -n $1 ]]; then
            declare -ng bep_cur_var_ref_node_raw_scalar_value=$bep_scalar_var_prefix$var_name
            bep_cur_var_ref_node_scalar_value+=$bep_cur_var_ref_node_raw_scalar_value
        fi

        bep_node_consume
        return 0
    else
        bep_node_recede
        return 1
    fi
}

# --------------------
# Ignored parse nodes
# --------------------

# --- Whitespace ---
bep_single_line_whitespace() {
    bep_node_start
    local $( bep_grep '[ \t]+' ws )
    (( bep_cur_index += ${#ws} ))

    bep_node_consume
    return 0
}

bep_whitespace() {
    bep_node_start
    local $( bep_grep '[ \t\n]+' ws )
    (( bep_cur_index += ${#ws} ))

    bep_node_consume
    return 0
}

# --- Comment ---
bep_comment() {
    bep_node_start
    local $( bep_grep '#.*?\n' comment_content )
    (( bep_cur_index += ${#comment_content} ))
    bep_node_consume
}

