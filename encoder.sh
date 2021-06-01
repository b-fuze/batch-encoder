#!/bin/bash
# vim:set shiftwidth=4 tabstop=4:

BATCH_ENCODER_VERSION=0.2.1

# Author: Mike32
#
# Print usage: encoder.sh -h
#
# This works in any *nix environment with at least Bash v4 
# and `ffmpeg` and `ffprobe` are in your PATH
#
# It also works on Windows via WSL as long as both `ffmpeg.exe` and 
# `ffprobe.exe` are in your PATH

# [1] TODO: Cache FFprobes output somewhere
# [2] TODO: Validate stream options
# [3] TODO: Batch video resolution (e.g 1080,720,360)
# [4] TODO: Show titles of Streams

shopt -s extglob
shopt -u nocaseglob

# Utility functions

# Bold formatting
b() {
    echo -en "\e[1m$1\e[0m"
}

# Output miscellaneous information
misc_info() {
    local msg=$1
    echo -e '\e[90m'"$msg"'\e[0m'
}

# Confirmation prompt
confirm() {
    echo -n "$1 (y/n) [$2]: "
    read _response
    _response=${_response,,*}

    if [[ ${_response:0:1} == y ]]; then
        return 0
    fi

    return 1
}

# Get key value from detail string structure
get_detail() {
    local key="$1"
    local details="$2"

    echo "$details" | grep -E "^$key:" | sed -Ee 's/^[^:]+:(.*)$/\1/'
}

# Convert paths for external Windows programs
HAS_CYGPATH=false
HAS_WSLPATH=false

path() {
    local __cur_path="$1"

    if [[ $IS_WINDOWS == true ]]; then
        if [[ $HAS_WSLPATH == true ]]; then
            wslpath -m "$__cur_path"
        elif [[ $HAS_CYGPATH == true ]]; then
            cypath.exe -w "$__cur_path"
        fi
    else
        echo -n "$__cur_path"
    fi
}

# Convert windows paths to nix
nix_path() {
    local __cur_path="$1"

    if [[ $IS_WINDOWS == true ]]; then
        if [[ $HAS_WSLPATH == true ]]; then
            wslpath -u "$__cur_path"
        elif [[ $HAS_CYGPATH == true ]]; then
            cypath.exe -u "$__cur_path"
        fi
    else
        echo -n "$__cur_path"
    fi
}

# Check for Windows paths (and convert them to *nix paths)
check_windows_path() {
    local path="$1"

    # Match against absolute paths on Windows
    if [[ $path =~ ^[A-Z]:\\ || $path =~ ^\\\\?wsl$\\ ]]; then
        nix_path "$path"
    else
        echo -n "$path"
    fi
}

# Hide temporary files on Windows
hide_tmp_file_windows() {
    local path=$1

    if [[ $IS_WINDOWS == true ]]; then
        # TODO: Maybe hide all files and not just ones in the Windows' drives
        if [[ $path =~ ^/mnt/ && -n $windows_attrib_executable ]]; then
            attrib.exe +s +h "$( path "$path" )" &> /dev/null
        fi
    fi
}

# Update encoder
update_encoder() {
    if ! which git &> /dev/null; then
        echo "Error: can't update without $( b git ). Install $( b git ) and try again" 1>&2
        return 1
    fi

    cd "$data_dir"
    if git rev-parse HEAD &> /dev/null; then
        local branch=$( git branch --show-current )
        local remote_name=$( git remote | head -n1 )
        local cur_commit=$( git rev-parse --short HEAD )

        echo -n "Loading latest version information..."

        git fetch "$remote_name" "$branch" -q
        local new_commit=$( git rev-parse --short "$remote_name/$branch" )

        # Clear line
        echo -ne '\e[?25h\e[2K\r'

        if [[ $cur_commit = $new_commit ]]; then
            echo "Already up to date"
            echo "Version $( b "$BATCH_ENCODER_VERSION" )-$cur_commit"
        else
            git checkout HEAD . -q
            git merge "$remote_name"/"$branch" -q
            local new_version=$( grep BATCH_ENCODER_VERSION -m 1 encoder.sh | sed -E 's/^.+=(.+)$/\1/' )
            echo "Updated to latest version"
            echo "From version $( b "$BATCH_ENCODER_VERSION" )-$cur_commit $( b $'\e[32m''->' ) $( b "$new_version" )-$new_commit"
        fi
    else
        echo "Error: can't update, not installed with Git" 1>&2
    fi
}

# Check for and load config
load_config() {
    local config=~/.config/batch-encoder-cfg.sh
    local parser=$data_dir/config/parser.sh

    if [[ -f $config && -f $parser ]]; then
        . "$parser"
        bep_cur_file=~/.config/batch-encoder-cfg.sh

        # Sync the relevant variables with the parser
        bep_sync defaults
        bep_sync ffmpeg_input_args
        bep_sync ffmpeg_output_args

        # Finally, parse the config file
        bep_parse < "$config"
        misc_info "Loaded config file"
    fi
}

# Print config when using --debug-config
print_config() {
    echo -e '\e[1m'"CONFIG:\e[0m"
    local IFS=$'\n'
    local keys=($( sort <<< "${!defaults[*]}" ))
    local longest_key=

    for key in "${keys[@]}"; do
        if (( ${#key} > ${#longest_key} )); then
            longest_key=$key
        fi
    done

    # Convert to whitespace
    local longest_key=$( tr -c '' ' ' <<< "$longest_key" )

    for key in "${keys[@]}"; do
        local key_length=${#key}
        echo -en '\e[32m'"  $key\e[0m:${longest_key:$key_length}"
        echo -en "\e[95m'\e[37m"
        echo -n "${defaults[$key]}"
        echo -e "\e[95m'\e[0m"
    done

    # TODO: DRY
    # Calculate padding
    local longest_arg=
    for arg in "${ffmpeg_input_args[@]}"; do
        if [[ ${arg:0:1} = - && ${#arg} -gt ${#longest_arg} ]]; then
            longest_arg=$arg
        fi
    done

    # Convert to whitespace
    local longest_arg=$( tr -c '' ' ' <<< "$longest_arg" )

    echo -en '\n\e[1m'"FFMPEG INPUT ARGS:\e[0m"
    local initial_newline=$'\n  '
    for arg in "${ffmpeg_input_args[@]}"; do
        local tail=
        case ${arg:0:1} in
            '-' )
                local arg_length=${#arg}
                local tail=${longest_arg:$arg_length}
                echo -en "\n  \e[95m'\e[37m"
                ;;
            * )
                echo -en "$initial_newline\e[95m'\e[37m"
                ;;
        esac
        echo -n "$arg"
        echo -en "\e[95m'\e[0m$tail"
        local initial_newline=
    done

    # Calculate padding
    local longest_arg=
    for arg in "${ffmpeg_output_args[@]}"; do
        if [[ ${arg:0:1} = - && ${#arg} -gt ${#longest_arg} ]]; then
            longest_arg=$arg
        fi
    done

    # Convert to whitespace
    local longest_arg=$( tr -c '' ' ' <<< "$longest_arg" )

    echo -en '\n\n\e[1m'"FFMPEG OUTPUT ARGS:\e[0m"
    local initial_newline=$'\n  '
    for arg in "${ffmpeg_output_args[@]}"; do
        local tail=
        case ${arg:0:1} in
            '-' )
                local arg_length=${#arg}
                local tail=${longest_arg:$arg_length}
                echo -en "\n  \e[95m'\e[37m"
                ;;
            * )
                echo -en "$initial_newline\e[95m'\e[37m"
                ;;
        esac
        echo -n "$arg"
        echo -en "\e[95m'\e[0m$tail"
        local initial_newline=
    done

    echo
}

# Print CLI args used
print_ffmpeg_args() {
    local ffmpeg_cmd=$1
    shift
    local args=("$@")

    echo -en '\e[90m'
    echo -n "$ffmpeg_cmd"
    echo -en '\e[0m '

    local next_arg=
    for arg in "${args[@]}"; do
    echo -n "$next_arg"

    if [[ ${arg:0:1} = - ]]; then
        next_arg=$'\e[35m'"$arg"$'\e[0m'
    else
        # Print $arg with any single quotes
        # escaped to allow easy copy pasting
        # reproducible FFmpeg commands
        next_arg=\'"${arg//\'/\'\\\'\'}"\'
    fi

    next_arg+=' '
    done

    next_arg=${next_arg% }
    echo "$next_arg"
}

# Human readable duration
human_duration() {
    local seconds="$1"
    local output=""

    # Hours
    if [[ $seconds -gt "60 * 60" ]]; then
        local hours=$(( seconds / 60 / 60 ))
        local output="${hours}h "
    fi

    # Minutes
    if [[ $seconds -gt 60 ]]; then
        local minutes=$(( (seconds / 60) % 60 ))
        local output="${output}${minutes}m "
    fi

    # Seconds
    local seconds=$(( seconds % 60 ))
    local output="${output}${seconds}s"

    echo "$output"
}

# Get first stream ID of a specific stream type
get_first_stream_id() {
    local type=$1
    local streams=$2
    grep -E "^ +Stream.+$type" -m 1 <<< "$streams" | sed -Ee 's/^.+Stream #0:([0-9]+).*$/\1/'
}

# Get video stream frame count
get_stream_framecount() {
    local cur_stream_details="$1"
    local duration="$( echo -n "$cur_stream_details" | grep -Eo 'Duration: [^,]+' | awk '{ print $2 }' )"
    local duration_secs=0
    local size=($((60 * 60)) 60 1)

    # Convert HH:MM:SS to just seconds
    local IFS=':'
    for dur in $duration; do
        local secs=$( bc <<< "scale=8; $dur * ${size[0]}" )
        local duration_secs=$( bc <<< "scale=8; $duration_secs + $secs" )
        local size=("${size[@]:1}")
    done

    # Get fps to get total frames
    local fps=$( grep -oP '\d+(.\d+)? fps' <<< "$cur_stream_details" | awk '{ print $1 }' )

    # Check if the user specified an alternate framerate
    if [[ $framerate != original ]]; then
        local fps=$framerate
    fi

    local total_frames=$( bc <<< "scale=8; $fps * $duration_secs" )
    local total_frames=$( printf "%.f" "$total_frames" )

    # Stream identifier
    local stream_id="$( grep -oP 'Stream #\d+:\d+' <<< "$cur_stream_details" | awk '{ print $2 }' )"

    # stream_id,frame_count,dur_secs
    echo "${stream_id#*:},$total_frames,$duration_secs"
}

# Run ffmpeg and print progress
run_ffmpeg() {
    local vid_details="$1"
    local vid_frames="$( get_detail "VSTREAM_FRAMES" "$vid_details" )"
    local vid_dir_out="$( dirname "$( get_detail "VIDEO_OUT" "$vid_details" )" )"
    local vid_file_out="$( basename "$( get_detail "VIDEO_OUT" "$vid_details" )" )"

    # Create temporary file to store FFmpeg errors
    local tmp_vid_ffmpeg_errors_filename=$( tr -sc '[:alnum:]' '-' <<< "$vid_file_out" | sed -Ee 's/^-+//;s/-+$//'  )
    local tmp_vid_ffmpeg_errors=$( dirname "$tmp_vid_enc_list" )/.batch-enc-ffmpeg-errors-${tmp_encoder_id:0:7}-$tmp_vid_ffmpeg_errors_filename
    encoder_tmp_files+=("$tmp_vid_ffmpeg_errors")
    touch "$tmp_vid_ffmpeg_errors"
    hide_tmp_file_windows "$tmp_vid_ffmpeg_errors"
    echo -n "" > "$tmp_vid_ffmpeg_errors"

    shift
    local ffmpeg_cmd=("${@}")

    # Mapping of stream id's to video stream frame counts and duration
    # TODO: Cleanup. This is probably over-engineered and useless
    local IFS=':'
    declare -A vid_stream_frames
    for vid_s_frames in $vid_frames; do
        local vid_stream_info_acts=(stream_id frames duration)
        local stream_id=
        local cur_vid_stream_frames=
        local cur_vid_stream_duration=

        local IFS=','
        for part in $vid_s_frames; do
            case ${vid_stream_info_acts[0]} in
                stream_id )
                    local stream_id="$part" ;;
                frames )
                    local cur_vid_stream_frames="$part" ;;
                duration )
                    local cur_vid_stream_duration="$part"
                    vid_stream_frames[$stream_id]="$cur_vid_stream_frames,$cur_vid_stream_duration"
            esac

            vid_stream_info_acts=("${vid_stream_info_acts[@]:1}")
        done
    done

    declare -A cur_progress

    # Hide cursor
    echo -en "\e[?25l"

    # Start FFmpeg
    "${ffmpeg_cmd[@]}" 2> "$tmp_vid_ffmpeg_errors" |
        while read -r line; do
            local key="${line%=*}"
            local value="${line#*=}"

            if [[ $key == progress ]]; then
                # Prepare data for calculating progress
                local enc_stream_info="${vid_stream_frames[${stream_id}]}"
                local enc_frame_count="${enc_stream_info%,*}"
                local enc_duration="${enc_stream_info#*,}"
                local enc_duration_final="$enc_duration"
                [[ $debug_run == true ]] && local enc_duration_final="$debug_run_dur"
                local enc_frame_count="$( printf "%.f" "$( bc <<< "scale=8; ($enc_duration_final / $enc_duration) * $enc_frame_count")" )"

                # Calculate progress' percentage
                local enc_pct_n="$( printf "%.f" "$( bc <<< "scale=8; (${cur_progress[frame]} / $enc_frame_count) * 100" )" )"
                local enc_pct_padding="   "
                local enc_pct="${enc_pct_padding:0:-${#enc_pct_n}}${enc_pct_n}%"
                if [[ "$( printf "%.f" "${cur_progress[fps]}" )" -gt 0 ]]; then
                    local eta_secs="$( printf "%.f" "$( bc <<< "scale=8; ($enc_frame_count - ${cur_progress[frame]}) / ${cur_progress[fps]}" )" )"
                else
                    local eta_secs=0
                fi

                # Clear line. Print progress, FPS, and ETA (with some pretty formatting)
                echo -en '\e[2K'"Progress \e[92m$( b "$enc_pct" ) FPS $( b "${cur_progress[fps]}" ) ETA $( b "$( human_duration "$eta_secs" )" )"

                # Reset cursor position to the beginning of the line
                echo -en "\r"
            else
                local cur_progress[$key]="$value"
            fi
        done

    local ffmpeg_status=${PIPESTATUS[0]}

    # Show cursor
    echo -en "\e[?25h"

    # Remove temporary FFmpeg error file or
    # print it to the user in case of error
    read -r -d '' ffmpeg_last_error_log < <( sed -Ee '/^\s*$/d' < "$tmp_vid_ffmpeg_errors" )
    rm "$tmp_vid_ffmpeg_errors"

    # Remove FFmpeg error log from list of temp files
    unset encoder_tmp_files[-1]

    # Return FFmpeg's exit status
    return $ffmpeg_status
}

# Utility for checking and adding either source
# video files or directories
add_source() {
    local source=$1

    if [[ -e $source ]]; then
        if [[ -f $source ]]; then
            vid_sources+=("$source")
        elif [[ -d $source ]]; then
            dir_sources+=("$source")
        fi
    else
        echo "Error: '$source': no such file or directory" 1>&2
    fi
}

# Main script logic
usage_section() {
    local section=$1
    local usage=$2
    local cur_section=${defaults[help_section]}

    if [[ $section == $cur_section || $cur_section == all ]]; then
        echo -n "$usage"
    fi
}

# Print usage/help
usage() {
    echo -n "
USAGE
    encoder.sh [sub | dub] [-r RES] [-a] [-s SOURCE] [-d DEST] [-R]
               [--burn-subs] [--watermark FILE] [--clean] [--force]
               [-w] [--watch-rescan] [--verbose-streams] [--fatal]
               [--debug-run [DUR]] [--version]
    encoder.sh update
    encoder.sh -h | --help

DESCRIPTION
    Encode all MKV and AVI and MP4 videos in the current
    directory (or subdirectories) to MP4 videos.
    Options are either set via optional arguments
    listed below or interactive prompts in the
    absence of such arguments. Arguments that accept
    values can be in the form --arg=value.

OPTIONS" | sed -Ee '1d'

    usage_section all "
    sub, dub
        Whether to encode subbed or dubbed.
        Defaults to subbed. Implies --auto.
"
    usage_section advanced "
    --target-lang LANG
        Target language that videos will be
        encoded to. Defaults to $( b en ).

    --origin-lang LANG
        Original language that videos are currently
        encoded in. Defaults to $( b jp ).
"
    usage_section basic "
    -r, --resolution RES
        RES can be one of $( b 240 ), $( b 360 ), $( b 480 ), $( b 640 ), $( b 720 ),
        $( b 1080 ), $( b 2160 ), or $( b original ). Original by default.

    -a, --auto, --no-auto
        Automatically determine appropriate audio
        and video streams. Implies --burn-subs
        in the absence of --no-burn-subs. Prompts
        by default.

    --burn-subs, --no-burn-subs
        Burn subtitles. Prompts by default.

    --recolor-subs
        Recolor PGS/VOB subtitles to neutral
        colors.
"
    usage_section advanced "
    --watermark FILE, --no-watermark
        Use a watermark .ass FILE. Defaults to
        AU watermark if it exists.
"
    usage_section basic "
    -s, --source DIR
        Source file or directory to encode. Can be
        used multiple times. Defaults to current
        directory if omitted.

    -d, --destination DIR
        Destination directory for all encodes.
        Will create the directory it it doesn't
        already exist. Defaults to source
        directory.
"
    usage_section advanced "
    -R, --recursive, --no-recursive
        Whether to recursively search subdirs for
        videos to encode. Won't by default.

    --out-suffix[=SUFFIX]
        Add a suffix to output video filenames.
        e.g. $( b '--out-suffix=-encoded' ) would encode
        foo.mkv into foo-encoded.mp4 instead
        of foo.mp4. Defaults to -out when SUFFIX
        is omitted.

    --clean
        Remove original videos after encoding.

    --force
        Overwrite existing videos. Won't by default.
"
    usage_section basic "
    -w, --watch
        Watch source directory recursively for new 
        videos.
"
    usage_section advanced "
    --watch-rescan
        Rescan the source directory on every file
        change event; don't trust inotify's
        information. Default on WSL.

    --watch-validate
        Validate files after detecting them while
        watching. Won't by default as it's optimistic
        and assumes the video is valid.

    --framerate NUM
        Set framerate for the video. Defaults to
        the original framerate.
"
    usage_section debug "
    --debug-run [DURATION]
        Test encoder by only encoding (optional) 
        DURATION in seconds of videos. When 
        DURATION is omitted it defaults to 5
        seconds.

    --debug-ffmpeg-args
        Display the FFmpeg command used

    --debug-ffmpeg-errors
        Display FFmpeg error log even after successful
        encodes.

    --debug-config
        Print the resulting configuration.
"
    usage_section advanced "
    --fatal
        Consider FFmpeg errors fatal and stop encoding
        all videos.

    --verbose-streams
        Print all streams and don't exclusively filter
        video, audio, and subtitle streams.

    --prompt-all
        Prompt for all videos even if they have identical
        stream tracks. Defaults to using the configuration
        of an earlier video with the same stream/track 
        structure without prompting.

    edit-config
        Edit config file in a file editor. Use --editor
        to choose an editor, e.g. $( b vim ) for Linux or
        $( b notepad.exe ) for Windows, which are also the
        defaults.

    load-config CONFIG_URL
        Download a new config file from CONFIG_URL and
        change the current to the new config.

    reset-config
        Removes the config file and resets all
        configuration to the defaults.
"
    echo -n "
    --version
        Print version.

    update
        Update encoder.sh to its latest version.

    -h, --help
        Show simplfied help.

    --help-advanced, --help-debug, --help-all
        Show help from advanced sections.
"
}

# Data dir with watermark (same as script folder)
data_dir="$(dirname $(readlink -f "${BASH_SOURCE[0]}"))"

# Some defaults
declare -A defaults
declare -A arg_mapping

# Arrays of sources to encode
vid_sources=()
dir_sources=()

defaults[res]=prompt                   # Default resolution (same as source)
defaults[auto]=null                    # Automatically determine streams
defaults[out_dir]=""                   # Output directory
defaults[recursive]=null               # Recursively encode subdirs
defaults[out_suffix]=false             # Append a suffix to output filename
defaults[out_suffix_name]=""           # Output filename suffix
defaults[force]=false                  # Overwrites existing encodes
defaults[watch]=false                  # Watch source directory for new videos
defaults[watch_rescan]=false           # Rescan the source dir for every inotify event
defaults[watch_validate]=false         # Validate last 10 seconds of files after detecting them from watch mode
defaults[clean]=false                  # Removes original video after encoding
defaults[burn_subs]=null               # Burns subtitles into videos
defaults[recolor_subs]=false           # Recolor subtitles to a neutral color
defaults[watermark]="$data_dir/au.ass" # Watermark video (with AU watermark by default)
defaults[locale]=null                  # Subbed or dubbed
defaults[target_lang]=en               # Target language to encode videos to
defaults[origin_lang]=jp               # Original language videos (or streams of interest thereof) were encoded in
defaults[framerate]=original           # Output framerate
defaults[debug_run]=false              # Only encode short durations of the video for testing
defaults[debug_run_dur]=5              # Debug run duration
defaults[debug_ffmpeg_errors]=false    # Don't remove FFmpeg error logs
defaults[debug_ffmpeg_args]=false      # Print FFmpeg cli args
defaults[fatal]=false                  # Fail on FFmpeg errors
defaults[verbose_streams]=false        # Don't filter video, audio, and subs streams, also print e.g attachment streams
defaults[prompt_all]=false             # Prompt for all videos, even ones with identical stream structures
defaults[edit_config]=false            # Whether to edit the config file or not
defaults[edit_config_editor]=""        # Default editor for edit-config command. If omitted is Vim on *nix and Notepad on Windows
defaults[download_config_url]=""       # URL to download a new config from
defaults[help_section]=""              # Help section to choose from: basic, advanced, debug, all

arg_mapping[-r]=--resolution
arg_mapping[-a]=--auto
arg_mapping[-d]=--destination
arg_mapping[-s]=--source
arg_mapping[-R]=--recursive
arg_mapping[-w]=--watch
arg_mapping[-h]=--help

# FFmpeg argument defaults
ffmpeg_input_args=(
    -hide_banner
    -loglevel warning
    -strict -2        # In case old version of FFmpeg to enable experimental AAC encoder
)

ffmpeg_output_args=(
    -y                # Overwrite existing files without prompting, we check instead
    -c:v libx264
    -preset veryslow
    -tune ssim,fastdecode,zerolatency
    -trellis 2
    -subq 11
    -me_method umh
    -crf 19
    -vsync 2
    -g 30
    -x264-params ref=6:deblock=1,1:bframes=8:psy-rd=1.5:aq-mode=3:aq-strength=1:psy-rd=1.50,0.60
    -profile:v high
    -level 4.1
    -b_strategy 1
    -bf 16
    -color_primaries bt709
    -color_trc bt709
    -colorspace bt709
    -pix_fmt yuv420p
    -c:a aac
    -ac 2
    -b:a 192k
    -sn
    -map_metadata -1
    -map_chapters -1
    -movflags +faststart # Web optimization
)

# Check for and load config
load_config

cur_arg="$1"
consume_next=false
consume_optional=false
consume_next_arg=
invalid_args=()

# Argument parsing stuff
while true; do
    # Check this argument isn't empty
    if [[ -n $cur_arg ]]; then
        # Check if this is parameter of a previous argument
        if [[ $consume_next == true ]]; then
            # If argument parmeter is optional and next arg is another argument, then skip to next argument
            if [[ $consume_optional == true ]] && [[ ${cur_arg:0:1} == "-" ]]; then
                consume_optional=false
                consume_next=false

                # Move on to next arg
                continue
            fi

            # Special handling for --source/-s values.
            if [[ $consume_next_arg = source ]]; then
                add_source "$cur_arg"
            else
                defaults[$consume_next_arg]="$cur_arg"
            fi

            consume_next=false
            consume_optional=false
        # Current arg isn't another arg's parameter
        else
            cur_base_arg=("$cur_arg")
            cur_base_arg_index=0

            while [[ -n ${cur_base_arg[$cur_base_arg_index]} ]]; do
                cur_arg_name=${cur_base_arg[$cur_base_arg_index]}
                cur_arg_param=

                if [[ $cur_arg_name =~ = ]]; then
                    cur_arg_param=${cur_arg_name#*=}
                    cur_arg_name=${cur_arg_name%%=*}
                fi

                case $cur_arg_name in
                    # Match all (listed) single char arguments either combined
                    # (e.g -aRs) or separate (e.g -a -R -s)
                    -+([adhsRrw]) )
                        opts=${cur_arg:1}
                        opt_length=${#opts}

                        # Remap single char arg to its full counterpart pushing it to $cur_base_arg
                        # to reprocess it
                        for (( i=0; i<opt_length; i++ )); do
                            arg_char=${opts:$i:1}
                            cur_base_arg+=("${arg_mapping[-$arg_char]}")
                        done

                        (( cur_base_arg_index++ ))
                        continue
                        ;;

                    # Match all full arguments
                    --resolution )
                        # Resolution is supplied as next arg
                        consume_next=true
                        consume_next_arg=res
                        ;;
                    --auto )
                        defaults[auto]=true
                        ;;
                    --no-auto )
                        defaults[auto]=false
                        ;;
                    --burn-subs )
                        defaults[burn_subs]=true
                        ;;
                    --no-burn-subs )
                        defaults[burn_subs]=false
                        ;;
                    --recolor-subs )
                        defaults[recolor_subs]=true
                        ;;
                    --watermark )
                        # Watermark .ass file supplied as next arg
                        consume_next=true
                        consume_next_arg=watermark
                        ;;
                    --no-watermark )
                        defaults[watermark]=
                        ;;
                    --destination )
                        # Directory is supplied as next arg
                        consume_next=true
                        consume_next_arg=out_dir
                        ;;
                    --source )
                        # Directory is supplied as next arg
                        consume_next=true
                        consume_next_arg=source
                        ;;
                    --recursive )
                        defaults[recursive]=true
                        ;;
                    --no-recursive )
                        defaults[recursive]=false
                        ;;
                    --out-suffix )
                        defaults[out_suffix]=true
                        defaults[out_suffix_name]=-out

                        # out-suffix's name is (optionally) supplied as next arg
                        consume_next=true
                        consume_optional=true
                        consume_next_arg=out_suffix_name
                        ;;
                    --force )
                        defaults[force]=true
                        ;;
                    --watch )
                        defaults[watch]=true
                        ;;
                    --watch-rescan )
                        defaults[watch_rescan]=true
                        ;;
                    --watch-validate )
                        defaults[watch_validate]=true
                        ;;
                    --clean )
                        defaults[clean]=true
                        ;;
                    --framerate )
                        consume_next=true
                        consume_next_arg=framerate
                        ;;
                    --debug-run )
                        defaults[debug_run]=true

                        # Debug run's duration is (optionally) supplied as next arg
                        consume_next=true
                        consume_optional=true
                        consume_next_arg=debug_run_dur
                        ;;
                    --debug-ffmpeg-errors )
                        defaults[debug_ffmpeg_errors]=true
                        ;;
                    --debug-ffmpeg-args )
                        defaults[debug_ffmpeg_args]=true
                        ;;
                    --debug-config )
                        print_config
                        exit 0
                        ;;
                    --fatal )
                        defaults[fatal]=true
                        ;;
                    --prompt-all )
                        defaults[prompt_all]=true
                        ;;
                    --verbose-streams )
                        defaults[verbose_streams]=true
                        ;;
                    --help-advanced )
                        # Print help and quit
                        defaults[help_section]=advanced
                        ;;
                    --help-debug )
                        # Print help and quit
                        defaults[help_section]=debug
                        ;;
                    --help-all )
                        # Print help and quit
                        defaults[help_section]=all
                        ;;
                    --help )
                        # Print help and quit
                        defaults[help_section]=basic
                        ;;
                    --origin-lang )
                        # Directory is supplied as next arg
                        consume_next=true
                        consume_next_arg=origin_lang
                        ;;
                    --target-lang )
                        # Directory is supplied as next arg
                        consume_next=true
                        consume_next_arg=target_lang
                        ;;
                    # Sub/dub
                    sub )
                        defaults[locale]=sub

                        # Implies --auto
                        defaults[auto]=true
                        ;;
                    dub )
                        defaults[locale]=dub

                        # Implies --auto
                        defaults[auto]=true
                        ;;
                    # Updates and versioning
                    --version )
                        echo "v$BATCH_ENCODER_VERSION"
                        exit
                        ;;
                    update )
                        update_encoder
                        exit $?
                        ;;
                    edit-config )
                        defaults[edit_config]=true
                        ;;
                    load-config )
                        consume_next=true
                        consume_next_arg=download_config_url
                        ;;
                    reset-config )
                        config_file=~/.config/batch-encoder-cfg.sh
                        if [[ -f $config_file ]]; then
                            if rm "$config_file"; then
                                echo "Reset successfully"
                            else
                                echo "Failed to reset config"
                                exit 1
                            fi
                        else
                            echo "Already reset"
                        fi
                        exit
                        ;;
                    --editor )
                        consume_next=true
                        consume_next_arg=edit_config_editor
                        ;;
                    * )
                        invalid_args+=("$cur_arg_name")
                esac

                # Assign values created by --arg=value syntax
                if [[ -n $cur_arg_param && $consume_next = true ]]; then
                    # Special handling for --source/-s values.
                    if [[ $consume_next_arg = source ]]; then
                        add_source "$consume_next"
                    else
                        defaults[$consume_next_arg]=$cur_arg_param
                    fi
                    consume_next=false
                    consume_optional=false
                fi

                (( cur_base_arg_index++ ))
            done
        fi
    fi

    # Process next arg
    shift && cur_arg="$1" || break
done

if [[ -n ${defaults[help_section]} ]]; then
    usage
    exit 0
fi

# Error on invalid arguments
if [[ ${#invalid_args[@]} -gt 0 ]]; then
    for arg in "${invalid_args[@]}"; do
        echo "Error: '$( b "$arg" )' isn't a valid command or option. Did you forget a space?" 1>&2
    done

    exit 1
fi

# Deconstruct default variables
res="${defaults[res]}"
auto="${defaults[auto]}"
out_dir="${defaults[out_dir]}"
recursive="${defaults[recursive]}"
force="${defaults[force]}"
out_suffix="${defaults[out_suffix]}"
out_suffix_name="${defaults[out_suffix_name]}"
watch="${defaults[watch]}"
watch_rescan="${defaults[watch_rescan]}"
watch_validate="${defaults[watch_validate]}"
clean="${defaults[clean]}"
burn_subs="${defaults[burn_subs]}"
recolor_subs="${defaults[recolor_subs]}"
watermark="${defaults[watermark]}"
locale="${defaults[locale]}"
target_lang="${defaults[target_lang]}"
origin_lang="${defaults[origin_lang]}"
framerate="${defaults[framerate]}"
debug_run="${defaults[debug_run]}"
debug_run_dur="${defaults[debug_run_dur]}"
debug_ffmpeg_errors="${defaults[debug_ffmpeg_errors]}"
debug_ffmpeg_args="${defaults[debug_ffmpeg_args]}"
fatal="${defaults[fatal]}"
prompt_all="${defaults[prompt_all]}"
verbose_streams="${defaults[verbose_streams]}"

# Encode videos in current directory by default if
# no other sources are provided
if [[ ${#vid_sources[@]} -eq 0 && ${#dir_sources[@]} -eq 0 ]]; then
    dir_sources=("$PWD")
fi

# Validate resolution variable
case $res in 
    240* | 360* | 480* | 720* | 1080* | 2160* )
        res=$( echo "$res" | grep -oE '^(240|360|480|720|1080|2160)' )
        ;;
    original | prompt )
        :
        ;;
    * )
        usage
        echo -e "\nInvalid resolution '$res'"
        exit 1
esac

# Validate framerate
if ! [[ $framerate = original || ( $framerate =~ ^[0-9]+(.[0-9]+)?$ && "$( bc <<< "$framerate > 12" )" = 1 ) ]]; then
    usage
    echo -e '\n'"Invalid or missing framerate '$framerate'. Must be an integer greater than 12."
    exit 1
fi

# Find FFmpeg executable
ffmpeg_executable=$( which ffmpeg )
ffprobe_executable=$( which ffprobe )
IS_WINDOWS=false
windows_attrib_executable=

# Check for Windows FFmpeg in WSL if we haven't found a *nix
# installed build
if [[ -z $ffmpeg_executable ]]; then
    ffmpeg_executable=$( which ffmpeg.exe )
    ffprobe_executable=$( which ffprobe.exe )
    IS_WINDOWS=true
fi

# If we're running Windows make sure we have a win 2 *nix path converter around
if [[ $IS_WINDOWS == true ]]; then
    # Check for either wslpath or cygpath
    if which wslpath &> /dev/null; then
        HAS_WSLPATH=true
    elif which cygpath &> /dev/null; then
        HAS_CYGPATH=true
    else
        echo "On Windows either 'wslpath' or 'cygpath.exe' is required."
        exit 1
    fi

    # Convert any windows provided paths to Linux
    new_vid_sources=()
    new_dir_sources=()

    for vid in "${vid_sources[@]}"; do
        new_vid_sources+=("$( check_windows_path "$vid" )")
    done
    for dir in "${dir_sources[@]}"; do
        new_dir_sources+=("$( check_windows_path "$dir" )")
    done

    vid_sources=("${new_vid_sources[@]}")
    dir_sources=("${new_dir_sources[@]}")
    out_dir=$( check_windows_path "$out_dir" )

    # Check for `attrib.exe` Windows executable so we can hide
    # the temporary files on Windows
    which attrib.exe &> /dev/null && windows_attrib_executable=true

    # Force watch rescans (inotify doesn't work properly on WSL)
    watch_rescan=true
fi

# Edit encoder config file
if [[ ${defaults[edit_config]} = true ]]; then
    edit_config_editor=${defaults[edit_config_editor]}

    if [[ -z $edit_config_editor ]]; then
        if [[ $IS_WINDOWS = true ]]; then
            edit_config_editor=notepad.exe
        else
            edit_config_editor=vim
        fi
    fi

    # Create config file if it doesn't exist already
    config_file=~/.config/batch-encoder-cfg.sh
    if [[ ! -f "$config_file" ]]; then
        if [[ -d "$data_dir" ]]; then
            cp "$data_dir/config/batch-encoder-cfg.sh" "$config_file"
        else
            echo "" > "$config_file"
        fi
    fi

    "$edit_config_editor" "$( path "$config_file" )"
    exit $?
fi

# Download new config file
if [[ -n ${defaults[download_config_url]} ]]; then
    new_config_url=${defaults[download_config_url]}
    config_file=~/.config/batch-encoder-cfg.sh
    downloading_message="Downloading new config..."

    if which curl &> /dev/null; then
        echo "$downloading_message"
        curl -sL "$new_config_url" > "$config_file"
    elif which wget &> /dev/null; then
        echo "$downloading_message"
        wget -q "$new_config_url" -O "$config_file"
    else
        echo "Error: can't download new config, need either $( b curl ) or $( b wget )" 1>&2
        exit 1
    fi

    if [[ $? = 0 ]]; then
        echo "Completed successfully"
        exit
    else
        echo "Error: problem downloading config file" 1>&2
        exit 1
    fi
fi

if [[ -z $ffmpeg_executable ]]; then
    echo "FFmpeg command not installed in your PATH, aborting..."
    exit 1
fi

if [[ -z $ffprobe_executable ]]; then
    echo "FFprobe command not installed in your PATH, aborting..."
    exit 1
fi

# Remove any repeating slashes (if any)
ffmpeg_executable=$( echo -n "$ffmpeg_executable" | tr -s / )
ffprobe_executable=$( echo -n "$ffprobe_executable" | tr -s / )

misc_info "Found FFmpeg: $ffmpeg_executable"
misc_info "Found FFprobe: $ffprobe_executable"

if [[ $ffmpeg_executable =~ .exe ]]; then
    if ! which wslpath &> /dev/null; then
        echo "WSLpath command not installed in your PATH, aborting..."
        exit 1
    else
        misc_info "Found WSLPath: $( which wslpath )"
    fi
fi

if [[ $watch == true ]]; then
    misc_info "Watch mode enabled"
fi

# Check for (optional) Watermark file
use_watermark=true

# See if watermark (or default watermark) was provided and then
# convert it to a *nix path if it isn't already
if [[ -n "$watermark" ]]; then
    original_watermark_path="$watermark"
    watermark=$( check_windows_path "$watermark" )

    if [[ ! -f "$watermark" ]]; then
        echo "Notice: Watermark '$original_watermark_path' not found"
        use_watermark=false
    fi
else
    use_watermark=false
fi

# Create temporary metadata files
tmp_encoder_id=$( date +%s%N | sha1sum ); tmp_encoder_id=${tmp_encoder_id:0:16}
tmp_encoder_tmpfile_dir=$( readlink -f "${out_dir:-.}" )
tmp_vid_enc_list=$tmp_encoder_tmpfile_dir/.batch-enc-list-$tmp_encoder_id
tmp_vid_enc_watch_list=$tmp_encoder_tmpfile_dir/.batch-enc-watch-list-$tmp_encoder_id
tmp_vid_enc_watch_sync=$tmp_encoder_tmpfile_dir/.batch-enc-watch-lock-$tmp_encoder_id
tmp_vid_enc_watch_invalid_list=$tmp_encoder_tmpfile_dir/.batch-enc-watch-invalid-list-$tmp_encoder_id

# Create temporary file dir if it doesn't exist
if [[ ! -d $tmp_encoder_tmpfile_dir ]]; then
  mkdir -p "$tmp_encoder_tmpfile_dir"
fi

encoder_tmp_files=(
    "$tmp_vid_enc_list"
    "$tmp_vid_enc_watch_list"
    "$tmp_vid_enc_watch_sync"
    "$tmp_vid_enc_watch_invalid_list"
)

# Create initially empty tmp files
for file in "${encoder_tmp_files[@]}"; do
    touch "$file"
    hide_tmp_file_windows "$file"
done

# Remove temporary files on Ctrl-C (SIGINT)
# if not processing videos
cleanup() {
    local is_trap_invocation=$1

    # Prompt the user whether they wish to quit, skip a video, or fix
    # the parameters of a previous video
    if [[ $is_processing_videos == true && $watch == false ]]; then
        local prompt_formatting=
        if [[ -n $is_trap_invocation ]]; then
            local prompt_formatting='\n'
        fi

        local prompt_formatting+='\n\e[92m\e[1m'

        echo -en "$prompt_formatting""Choose next action"'\e[0m'" [$( b "Q" )uit, $( b "S" )kip, $( b "F" )ix, $( b "N" )umber]: "
        local next_action
        read -r next_action
        local next_action=${next_action,,*}

        case "${next_action:0:1}" in
            n )
                old_video_index=$(( cur_video_index ))
                echo -n "Enter video number [previous]: "

                local next_video
                read -r next_video

                # Adjust the number from the user to the index
                if [[ -n next_video ]]; then
                    (( next_video -= 2 ))
                # Use the previous video as default
                else
                    local next_video=$(( cur_video_index - 1 ))
                    old_video_index=-1
                fi

                cur_video_index=$next_video
                ;;
            f )
                (( cur_video_index-- ))
                ;;
            s )
                echo -en '\e[95m'"Skipped \e[1m$(( cur_video_index + 1 )):\e[0m \e[37m"
                echo -n  "$( basename "${videos[$cur_video_index]}" )"
                echo -e "\e[0m"
                ;;
            q )
                is_processing_videos=false
                cleanup true
                ;;
            * )
                cleanup
                ;;
        esac

    else
        for file in "${encoder_tmp_files[@]}"; do
            if [[ -f "$file" ]]; then
                rm "$file"
            fi
        done

        if [[ -n $is_trap_invocation ]]; then
            echo -e '\e[?25h\e[2K\r'"Exiting batch encoder"
        fi
        exit
    fi
}

trap 'cleanup true' INT

# Batch Encoder custom exit
be_exit() {
    cleanup 1
    exit $1
}

# Initially empty $videos array
videos=()

# (Maybe recursively) find all videos in the current directory and populate $videos
# array with them
find_source_videos() {
    local quiet="$1"
    local -A out_videos=()
    videos=()
    IFS=$'\n'
    shopt -s nocaseglob

    # Add videos from $dir_sources
    if [[ $recursive == true ]]; then
        [[ -z $quiet ]] && echo -en '\n'"Searching recursively for video sources... "
        # TODO: Make the recursive match not stupid and repetitive
        for dir in "${dir_sources[@]}"; do
            for file in "$dir"/*; do
                if [[ -d $file ]]; then
                    for inner_file in "$file"/*; do
                        if [[ -f $inner_file ]]; then
                            # Check lower-case'd filename match the correct
                            # filename extension
                            if [[ ${inner_file,,*} =~ \.(mkv|avi|mp4)$ ]]; then
                                videos+=("$inner_file")
                            fi
                        fi
                    done
                else
                    # Check lower-case'd filename match the correct
                    # filename extension
                    if [[ ${file,,*} =~ \.(mkv|avi|mp4)$ ]]; then
                        videos+=("$file")
                    fi
                fi
            done
        done
    else
        [[ -z $quiet ]] && echo -en '\n'"Searching source directories for video sources... "

        for dir in "${dir_sources[@]}"; do
            for file in "$dir"/*; do
                if [[ -f $file ]]; then
                    # Check lower-case'd filename match the correct
                    # filename extension
                    if [[ ${file,,*} =~ \.(mkv|avi|mp4)$ ]]; then
                        videos+=("$file")
                    fi
                fi
            done
        done
    fi

    # Add videos from $vid_sources
    videos+=("${vid_sources[@]}")

    # Find all conflicts between input *.mp4 files and
    # output *.mp4 that are in the same dir and resolve
    # them by removing them from the $video array which
    # lists videos that will be encoded
    local -A initial_conflict=()

    # Build a list of output videos
    for video in "${videos[@]}"; do
        local out_video=${video%.*}$out_suffix_name.mp4

        if [[ -z ${out_videos[$out_video]} ]]; then
            out_videos[$out_video]=1
        else
            initial_conflict[$video]=1
        fi
    done

    # Filter all conflicting output videos from input videos
    local new_videos=()
    for video in "${videos[@]}"; do
        if [[ -z ${out_videos[$video]} && -z ${initial_conflict[$video]} ]]; then
            new_videos+=("$video")
        fi
    done

    # Update list with conflict-free videos
    videos=("${new_videos[@]}")

    # Exit if no videos found
    if [[ ${#videos[@]} == 0 ]] && [[ $watch == false ]]; then
        [[ -z $quiet ]] && echo "No videos found"
        be_exit 0
    fi
}

# A video stream processing prompt that can be
# cancelled and repeated
process_videos_prompt() {
    local video=$1
    local vid_dir=$2
    local vid_file=$3
    local video_details_outfile=$4

    local streams=
    local vid_out="$vid_dir/${vid_file%.*}$out_suffix_name.mp4"
    local cur_vid_auto=$auto
    local cur_vid_details=
    local video_stream=
    local audio_stream=
    local subtitle_stream=
    local subtitle_stream_type=
    local vid_burn_subs=$burn_subs

    # Get list of all streams
    local streams=$( "$ffprobe_executable" "$( path "$video" )" 2>&1 )
    local streams_hash=$( grep -E '^ +Stream' <<< "$streams" | grep -F -e ' Video: ' -e ' Audio: ' -e ' Subtitle: ' | sha256sum )

    # Duration line is independent of streams
    local vid_duration_line=$( echo -n "$streams" | grep "Duration: " )

    # Get all video streams' (estimated) frame counts. Exclude video streams
    # that are just attached pictures
    local vid_video_streams="$( echo "$streams" | grep 'Stream #0' | grep " Video" | grep -v "attached pic" )"
    local cur_vid_vid_streams=()

    # Loop all possible video streams
    local IFS=$'\n'
    for cur_vid_stream_details in $vid_video_streams; do
        local vid_stream_framecount="$( get_stream_framecount "$( echo -en "$vid_duration_line\n$cur_vid_stream_details" )" )"
        local cur_vid_vid_streams+=("$vid_stream_framecount")
    done

    # Get the video stream height
    local video_stream_height=$( sed -Ee '2,$d; s/^.+[0-9]+[xX]([0-9]+).+$/\1/' <<< "$vid_video_streams" )

    # If this video has identical stream structure to previous videos
    # then reuse the previous video's configuration and exit
    if [[ $prompt_all = false && -n ${video_details_hashed[$streams_hash]} ]]; then
        local cached_vid_details=${video_details_hashed[$streams_hash]}
        local cur_vid_details=$(cat <<VID
VIDEO:$video
VIDEO_OUT:$vid_out
VIDEO_HEIGHT:$video_stream_height
VSTREAM_FRAMES:${cur_vid_vid_streams[*]}
$( grep -vE -e '^VIDEO:' -e '^VIDEO_OUT:' -e '^VIDEO_HEIGHT:' -e '^VSTREAM_FRAMES:' <<< "$cached_vid_details" )
VID
)
        echo -n "$cur_vid_details" > "$video_details_outfile"
        return
    fi

    if [[ $cur_vid_auto == null ]]; then
        confirm "Find streams automatically?" "y" && cur_vid_auto=true
    fi

    # Detect subtitle streams
    local cur_vid_has_subtitles=true
    local subtitle_stream
    local cur_vid_sub_streams=$( grep -E "Stream #.+Subtitle" <<< "$streams" )

    if [[ -z "$cur_vid_sub_streams" ]]; then
        local cur_vid_has_subtitles=false
    fi

    # Determine streams either automatically or by prompt
    if [[ $cur_vid_auto == true ]]; then
        if [[ $locale != null ]]; then
            # Create sub/dub automatically
            # Determine audio stream
            local -A audio_id_lang_map=()
            local -A audio_langs=()
            local audio_default_id=
            local audio_default_lang=
            local audio_lang_set=() audio_id_set=()
            local -A subtitle_id_lang_map=()
            local -A subtitle_langs=()
            local subtitle_default_id=
            local subtitle_default_lang=
            local subtitle_lang_set=() subtitle_id_set=()

            IFS=$'\n'
            for astream in $( grep -Ee '^ +Stream #.+ Audio: ' <<< "$streams" ); do
                if [[ $astream =~ \#[0-9]+:([0-9]+)\(([^()]+)\) ]]; then
                    local astream_id=${BASH_REMATCH[1]}
                    local astream_lang=${BASH_REMATCH[2]}
                    audio_id_lang_map[$astream_id]=$astream_lang
                    audio_langs[$astream_lang]=1

                    if [[ $astream == *(default)* ]]; then
                        audio_default_id=$astream_id
                        audio_default_lang=$astream_lang
                    fi
                else
                    echo "Error: determining localized audio streams failed" 1>&2
                fi
            done

            for sstream in $( grep -Ee '^ +Stream #.+ Subtitle: ' <<< "$streams" ); do
                if [[ $sstream =~ \#[0-9]+:([0-9]+)\(([^()]+)\) ]]; then
                    local sstream_id=${BASH_REMATCH[1]}
                    local sstream_lang=${BASH_REMATCH[2]}
                    subtitle_id_lang_map[$sstream_id]=$sstream_lang
                    subtitle_langs[$sstream_lang]=1

                    if [[ $sstream == *(default)* ]]; then
                        subtitle_default_id=$sstream_id
                        subtitle_default_lang=$sstream_lang
                    fi
                else
                    echo "Error: determining localized subtitle streams failed" 1>&2
                fi
            done

            audio_lang_set=("${!audio_langs[@]}")
            subtitle_lang_set=("${!subtitle_langs[@]}")
            audio_id_set=("${!audio_id_lang_map[@]}")
            subtitle_id_set=("${!subtitle_id_lang_map[@]}")

            # declare -p audio_id_lang_map
            # declare -p audio_langs
            # declare -p audio_default_id
            # declare -p audio_default_lang
            # declare -p audio_lang_set
            # declare -p audio_id_set
            # declare -p subtitle_id_lang_map
            # declare -p subtitle_langs
            # declare -p subtitle_default_id
            # declare -p subtitle_default_lang
            # declare -p subtitle_lang_set
            # declare -p subtitle_id_set

            if [[ $locale = sub ]]; then
                # Encode a video with subs
                if [[ -n $subtitle_default_id ]]; then
                    # We have a default subtitle track, so use
                    # the first non-default subtitle track
                    for sstream_id in "${subtitle_id_set[@]}"; do
                        if [[ $sstream_id != $subtitle_default_id ]]; then
                            subtitle_stream=$sstream_id
                            break
                        fi
                    done
                elif [[ ${#subtitle_id_set[@]} -gt 1 ]]; then
                    # We have more than one subtitle track
                    # without any defaults, use the second one
                    subtitle_stream=${subtitle_id_set[1]}
                elif [[ ${#subtitle_id_set[@]} -gt 0 ]]; then
                    # We only have one choice of subtitle
                    # track, so we'll use it
                    subtitle_stream=${subtitle_id_set[0]}
                fi

                if [[ ${#audio_lang_set[@]} -gt 1 ]]; then
                    # We actually have labeled audio tracks,
                    # use the track labeled with the origin
                    # langauge
                    local lang_regex="^$origin_lang.*"

                    for id in "${audio_id_set[@]}"; do
                        if [[ ${audio_id_lang_map[$id]} =~ $lang_regex ]]; then
                            audio_stream=$id
                            break
                        fi
                    done
                elif [[ -n $audio_default_id ]]; then
                    # We have a default track, we'll
                    # assume it's the origin language
                    audio_stream=$audio_default_id
                else
                    # We don't have labeled or default audio
                    # tracks, so we'll use the first audio
                    # track assuming that it's the origin lang
                    audio_stream=${audio_id_set[0]}
                fi
            else
                # Encode a video dubbed
                local lang_regex="^$target_lang.*"
                if [[ $audio_default_lang =~ $lang_regex && -n $subtitle_default_id ]]; then
                    # Default audio is dubbed and it has default
                    # subtitles, we'll burn them
                    subtitle_stream=$subtitle_default_id
                else
                    # We don't have obvious subtitles to burn,
                    # so we'll disable subtitles for this dubbed
                    # encode
                    vid_burn_subs=false
                fi

                if [[ ${#audio_lang_set[@]} -gt 1 ]]; then
                    # Audio seems to be labeled, get the
                    # one with the correct label
                    for id in "${audio_id_set[@]}"; do
                        if [[ ${audio_id_lang_map[$id]} =~ $lang_regex ]]; then
                            audio_stream=$id
                            break
                        fi
                    done
                elif [[ ${#audio_id_set[@]} -gt 1 ]]; then
                    # Audio doesn't seem to be labeled,
                    # go for the second one
                    audio_stream=${audio_id_set[1]}
                elif [[ ${#audio_id_set[@]} -eq 1 ]]; then
                    # We only have one track, let's use it
                    audio_stream=${audio_id_set[0]}
                fi
            fi

            # Determine subtitle stream type
            if [[ -n $subtitle_stream ]]; then
                local subtitle_stream_type=$( grep -E 'Stream #[0-9]:'"$subtitle_stream"'[^0-9]+.+Subtitle' -m 1 <<< "$streams" | sed -Ee 's/^.+Subtitle: ([a-z_]+).*$/\1/' )
                vid_burn_subs=true
            fi
        else
            # Original automatic behavior
            #
            # Burns subs automatically too (mirroring Meow's original script)
            [[ $vid_burn_subs == null ]] && vid_burn_subs=true
        fi
    else
        # Filter non video/audio/subtitle streams
        local vid_sed_filter_stream_options=(-n -e '/Video|Audio|Subtitle/p')

        if [[ $verbose_streams == true ]]; then
            local vid_sed_filter_stream_options=()
        fi

        # Print streams human-readable
        echo "$streams" | grep 'Stream #0' | 
            sed -Ee 's/Stream #0:([0-9]+):/Stream \1 ->/' \
                -e 's/Stream #0:([0-9]+)([^:]+): ([^:]+)/Stream \1 -> \3 \2/' \
                -e 's/(Video|Audio|Subtitle|Attachment)/\x1B[1m\1\x1B[0m/' "${vid_sed_filter_stream_options[@]}"

        # If there are at least 2 video or audio streams then prompt for
        # either, otherwise just select the only stream in the video
        local vid_audio_stream_count=$( grep -E 'Audio' -c <<< "$streams" )
        local video_stream
        local audio_stream

        # Determine which video stream to use
        if (( ${#cur_vid_vid_streams[@]} > 1 )); then
            echo -n "Select Video: "
            read video_stream
            local video_stream=$( sed -Ee 's/^\s*([0-9]+).*/\1/' <<< "$video_stream" )
        else
            local video_stream=$( get_first_stream_id "Video" "$streams" )
        fi

        # Determine which audio stream to use
        if (( vid_audio_stream_count > 1 )); then
            echo -n "Select Audio: "
            read audio_stream
            local audio_stream=$( sed -Ee 's/^\s*([0-9]+).*/\1/' <<< "$audio_stream" )
        else
            local audio_stream=$( get_first_stream_id "Audio" "$streams" )
        fi
    fi

    # If we're not automatically detecting streams prompt for the subtitle
    # stream
    if [[ $cur_vid_auto != true && ( $vid_burn_subs == null || $vid_burn_subs == true ) ]]; then
        if [[ $cur_vid_has_subtitles == true ]]; then
            # If it's not automatically detecting streams and we're going
            # to burn subtitles, or we confirm the user wants to burn subtitles
            # then we prompt for the subtitle stream
            if [[ $auto != true ]] && ( [[ $vid_burn_subs == true ]] || confirm "Burn subtitles?" "n" ); then
                local vid_burn_subs=true

                # If there's more than one subtitle stream then prompt
                # for the specific one
                if [[ "$( wc -l <<< "$cur_vid_sub_streams" )" -gt 1 ]]; then
                    echo -n "Select Subtitle [default]: "
                    read subtitle_stream
                    local subtitle_stream_type=$( grep -E -m 1 "Stream #0:$subtitle_stream[^0-9]" <<< "$streams" | sed -Ee 's/^.+Subtitle: ([a-z_]+).*$/\1/' )
                fi
            fi
        else
            echo "No subtitles detected"
        fi
    fi

    # No matter the settings, disable burning subtitles for this
    # video since it doesn't have any subtitles
    if [[ $cur_vid_has_subtitles == false ]]; then
        local vid_burn_subs=false
    # Otherwise if the user didn't select a subtitle stream determine
    # the subtitle type and set the first subtitle stream as default
    elif [[ -z $subtitle_stream_type ]]; then
        # TODO: DRY
        local subtitle_stream=$( grep -E 'Subtitle.+default' <<< "$streams" | sed -Ee 's/^.+Stream #0:([0-9]+).*$/\1/' )
        local subtitle_stream_type=$( grep -E 'Subtitle.+default' <<< "$streams" | sed -Ee 's/^.+Subtitle: ([a-z_]+).*$/\1/' )

        # If the default subtitle wasn't detected then just use the first
        # subtitle
        if [[ -z $subtitle_stream_type ]]; then
            local subtitle_stream=$( get_first_stream_id "Subtitle" "$streams" )
            local subtitle_stream_type=$( grep -E 'Stream.+Subtitle' -m 1 <<< "$streams" | sed -Ee 's/^.+Subtitle: ([a-z_]+).*$/\1/' )
        fi
    fi

    # Find the relative subtitle stream number
    local subtitle_stream_index=0

    if [[ $cur_vid_has_subtitles == true ]]; then
        IFS=$'\n'
        for sstream in $( grep -F 'Stream #' <<< "$streams" | grep -F ': Subtitle' ); do
            if grep -qF 'Stream #0:'"$subtitle_stream" <<< "$sstream"; then
                break
            fi

            (( subtitle_stream_index++ ))
        done
    fi

    # Set video stream if it's empty (from --auto)
    [[ -z $video_stream ]] && local video_stream=$( get_first_stream_id "Video" "$streams" )

    # Get current audio stream and check its codec to determine if it will use AAC passthrough
    local current_audio_stream=$( [[ -z $audio_stream ]] && get_first_stream_id "Audio" "$streams" || echo "$audio_stream" )
    local audio_stream_codec=$( grep -E 'Stream #0:'$current_audio_stream'[^0-9]' <<< "$streams" | awk '{ print $4 }' )
    local audio_aac_passthrough=false

    if [[ $audio_stream_codec = aac ]]; then
        audio_aac_passthrough=true
    fi

    IFS=':'
    # Save video details' struct
    local cur_vid_details=$(cat <<VID
VIDEO:$video
VIDEO_OUT:$vid_out
VIDEO_HEIGHT:$video_stream_height
AUTO:$cur_vid_auto
VSTREAM:$video_stream
ASTREAM:$audio_stream
ASTREAM_PASSTHROUGH:$audio_aac_passthrough
HAS_ASTREAM:$( get_first_stream_id "Audio" "$streams" )
SSTREAM:$subtitle_stream
SSTREAM_INDEX:$subtitle_stream_index
SSTREAM_TYPE:$subtitle_stream_type
VSTREAM_FRAMES:${cur_vid_vid_streams[*]}
BURNSUBS:$vid_burn_subs
STREAMS_HASH:$streams_hash
VID
)

    echo -n "$cur_vid_details" > "$video_details_outfile"
}

# Initially empty video details
video_details=()
declare -A video_details_hashed=()
video_count=0
video_successful_count=0
cur_video_index=0 # TODO: This variable is used across different functions, possibly problematic
old_video_index=-1

is_processing_videos=false
processing_video_pid=0

# Process all videos in the global $videos array and save the results to
# $video_details
process_videos() {
    local is_watch_invocation=$1

    # If the user send SIGINT then we'll know that we're processing videos
    # from here
    is_processing_videos=true

    video_details=()
    video_count=${#videos[@]}
    echo "Found $video_count videos""$is_watch_invocation"
    echo -e '\n\e[95m\e[1m'"➤ Processing videos..."'\e[0m'

    echo -e '\n\e[92m\e[1m'"Note:\e[0m \e[37m""Press \e[1m""Ctrl-C\e[0m\e[37m to toggle the menu\e[0m"

    # Gather preliminary information about the videos
    for (( ; cur_video_index < ${#videos[@]}; cur_video_index++ )); do
        video=${videos[$cur_video_index]}
        vid_dir="$( dirname "$video" )"
        vid_dir_print="$( dirname "$video" )"
        vid_file="$( basename "$video" )"
        old_video_index_value=$old_video_index
        old_video_index=-1
        cur_video_processing_index=$cur_video_index

        # Don't print dir name if it's the current dir
        if [[ "$( readlink -f "$vid_dir_print" )" = "$( readlink -f . )" ]]; then
            vid_dir_print=
        else
            vid_dir_print=$( basename "$vid_dir_print" )/
        fi

        echo -e "\nProcessing [$(( cur_video_index + 1 ))/$video_count] \e[32m$vid_dir_print\e[92m$vid_file\e[0m..."

        # Create tmp file to store the video details inside
        local video_details_outfile=$tmp_encoder_tmpfile_dir/.batch-enc-vid-detail-$cur_video_index-$tmp_encoder_id
        echo -n "" > "$video_details_outfile"
        encoder_tmp_files+=("$video_details_outfile")
        hide_tmp_file_windows "$video_details_outfile"

        # Prompt "asynchronously" for the user details, using a disposable subshell
        # for the ability to kill it and respawn another
        process_videos_prompt "$video" "$vid_dir" "$vid_file" "$video_details_outfile" < /dev/stdin &
        processing_video_pid=$!

        wait $processing_video_pid

        # Fetch the generated details
        cur_vid_details=$(< "$video_details_outfile")

        # Only add these new details if this current processing wasn't changed
        if [[ $cur_video_index = $cur_video_processing_index ]]; then
            video_details[$cur_video_index]="$cur_vid_details"
            video_details_hash=$( get_detail "STREAMS_HASH" "$cur_vid_details" )
            video_details_hashed[$video_details_hash]=$cur_vid_details
        fi

        # Remove the video detail tmp file
        rm "$video_details_outfile"
        unset encoder_tmp_files[-1]

        # Check if this video was changed out of order
        if (( old_video_index_value > -1 )); then
            cur_video_index=$(( old_video_index_value - 1 ))
        fi
    done

    # INT (ctrl-c) signals will now force quit batch encoder
    is_processing_videos=false
}

# FFmpeg errors from most recent encoding
ffmpeg_last_error_log=""

# Only encode 5 seconds for debugging
if [[ $debug_run == true ]]; then
    ffmpeg_output_args+=(-t $debug_run_dur)
fi

# Start encoding videos in the $video_details array containing information
# gathered from processing step
start_encoding() {
    echo -e '\n\e[95m\e[1m'"➤ Encoding videos..."'\e[0m'

    cur_video_index=0
    for details in "${video_details[@]}"; do
        (( cur_video_index++ ))

        # Check if this video was skipped
        if [[ -z $details ]]; then
            continue
        fi

        video="$( get_detail "VIDEO" "$details" )"
        video_out="$( get_detail "VIDEO_OUT" "$details" )"
        video_height="$( get_detail "VIDEO_HEIGHT" "$details" )"
        vid_auto="$( get_detail "AUTO" "$details" )"
        video_stream="$( get_detail "VSTREAM" "$details" )"
        audio_stream="$( get_detail "ASTREAM" "$details" )"
        audio_stream_passthrough="$( get_detail "ASTREAM_PASSTHROUGH" "$details" )"
        has_audio_stream="$( get_detail "HAS_ASTREAM" "$details" )"
        subtitle_stream="$( get_detail "SSTREAM" "$details" )"
        subtitle_stream_index="$( get_detail "SSTREAM_INDEX" "$details" )"
        subtitle_stream_type="$( get_detail "SSTREAM_TYPE" "$details" )"
        vid_burn_subs="$( get_detail "BURNSUBS" "$details" )"
        vid_res=$res

        if [[ -n $out_dir ]]; then
            # Store videos in $out_dir
            vid_abs_out="$out_dir/$( basename "$( dirname "$video_out" )" )/$( basename "$video_out" )"
        else
            # Store videos in their current directories
            if [[ ${video_out:0:1} = / ]]; then
                vid_abs_out=$video_out
            else
                vid_abs_out=$PWD/$video_out
            fi
        fi
        vid_abs_out_dir="$( dirname "$vid_abs_out" )"

        # Initialize video filters with watermark (if it exists)
        if [[ $use_watermark == true ]]; then
            vid_filter_args=("subtitles=\\'$( path "$watermark" )\\'")
        else
            vid_filter_args=()
        fi

        # Empty second filter graph (for VOBSub/PGS)
        vid_filter_second_filtergraph_args=

        # Make local copy of ffmpeg output args
        vid_output_args=("${ffmpeg_output_args[@]}")

        # Major video path components split for formatting purposes
        # Don't print dir if it's just './'
        vid_dir_print="$( basename "$( dirname "$video" )" )/"
        vid_file="$( basename "$video" )"

        # Don't print dir name if it's the current dir
        if [[ "$( readlink -f "$( dirname "$video" )" )" = "$( readlink -f . )" ]]; then
            vid_dir_print=
        fi

        vid_out_dir="$( dirname "$video_out" )/"
        vid_out_dir=${vid_out_dir#./}
        vid_out_file="$( basename "$video_out" )"

        # Skip video if it exists and force(fully overwriting) isn't enabled
        if [[ $force != true ]] && [[ -f "$vid_abs_out" ]]; then
            echo -e '\n'"Skipping [$cur_video_index/$video_count] \e[32m$vid_dir_print\e[92m$vid_file\e[0m..."
            continue
        fi

        # Burn subs
        if [[ $vid_burn_subs == true ]]; then
            if [[ $subtitle_stream_type == ass || $subtitle_stream_type == subrip ]]; then
                # Burn ASS subtitles
                #
                # Because FFmpeg's video filters' parser has crazy rules for escaping...
                # Ref: https://ffmpeg.org/ffmpeg-filters.html#Notes-on-filtergraph-escaping
                #
                # Monstrosity of escaping inbound...
                local vid_subtitle_filter_arg="subtitles=$( path "$video" | sed -Ee 's/([][,=])/\\\1/g' -e 's/('\'')/\\\\\\''\1/g' -Ee 's/(:)/\\\\''\1/g' )"

                # If a specific subtitle stream was selected by the user then
                # forward that to FFmpeg
                if [[ $subtitle_stream =~ ^[0-9]+$ ]]; then
                    local vid_subtitle_filter_arg+=":si=$subtitle_stream_index"
                fi

                vid_filter_args+=("$vid_subtitle_filter_arg")
                vid_output_args+=(-map 0:v:0) # First/default video stream
            elif [[ $subtitle_stream_type == dvd_subtitle || $subtitle_stream_type == hdmv_pgs_subtitle ]]; then
                # Burn VOBsub/PGS subtitles
                local vid_sub_recolor=

                if [[ $recolor_subs == true ]]; then
                    # local vid_sub_recolor=",eq=saturation=0"
                    local vid_sub_recolor=",hue=s=0,curves=preset=lighter,curves=preset=lighter"
                fi

                vid_filter_second_filtergraph_args="[0:$subtitle_stream]scale=-2:$video_height$vid_sub_recolor[subs]; [0:v][subs]overlay"
                vid_output_args+=(-map "[v]")
            else
                echo "Error: Subtitle type '$subtitle_stream_type' not supported"
            fi
        else
            # This video won't burn any subs so make sure to
            # -map the video source
            vid_output_args+=(-map 0:$video_stream)
        fi

        if [[ -n $has_audio_stream ]]; then
            # Choose different audio stream
            if [[ -n $audio_stream ]]; then
                vid_output_args+=(-map 0:$audio_stream)
            else
                # Use first audio stream as default
                vid_output_args+=(-map 0:a:0)
            fi
        fi

        # Check if using AAC passthrough
        if [[ $audio_stream_passthrough = true ]]; then
            vid_output_args+=(-c:a copy)
        fi

        # Set framerate
        if ! [[ $framerate = original ]]; then
            vid_output_args+=(-r $framerate)
        fi

        # Create output dir if it doesn't exist already
        if [[ ! -d "$vid_abs_out_dir" ]]; then
            mkdir -p "$vid_abs_out_dir"
            successfully_created_dir=$?

            if [[ $successfully_created_dir != 0 ]]; then
                echo -e "\e[91mFatal:\e[0m Couldn't create output dir '$vid_abs_out_dir', aborting..."
                be_exit 1
            fi
        fi

        # Everything checks out, time to start encoding
        echo -e "\nEncoding [$cur_video_index/$video_count] \e[32m$vid_dir_print\e[92m$vid_out_file\e[0m"
        echo -e   "    from \e[90m$vid_dir_print$vid_file\e[0m"

        # Check if video resolution is specified by user or automatic
        [[ $vid_res == prompt ]] && vid_res=original

        if [[ $vid_res != original ]]; then
            # -1 and -2 maintain aspect ratio, but -2 will be divisible by 2 (and thus suitable for mp4/YUV 4:2:0)
            # Grabbed from here: https://stackoverflow.com/a/29582287
            vid_filter_args+=("scale=-2:$vid_res")
        fi

        # Append video filter args to output args
        IFS=","
        local filter_complex_args="${vid_filter_args[*]}"
        if [[ -n $vid_filter_second_filtergraph_args ]]; then
            # Prepend comma to `filter_complex_args` if any
            if [[ -n $filter_complex_args ]]; then
                local filter_complex_args=','$filter_complex_args
            fi

            # Put VOBSub filter at the beginning
            local filter_complex_args="${vid_filter_second_filtergraph_args}${filter_complex_args}[v]"
        fi

        # If either watermark or subs will be burned then provide
        # -filter_complex, otherwise omit it
        if [[ -n "$( tr -d '[:blank:]' <<< "$filter_complex_args" )" ]]; then
            vid_output_args+=(-filter_complex "$filter_complex_args")
        fi

        # Print progress to stdout
        vid_output_args+=(-progress pipe:1)

        # Create output file to avoid `wslpath` complaining it doesn't exist
        touch "$vid_abs_out"

        # Create FULL ffmpeg cli and args
        vid_full_cmd=("$ffmpeg_executable" "${ffmpeg_input_args[@]}" -i "$( path "$video" )" "${vid_output_args[@]}" "${ffmpeg_size[@]}" "$( path "$vid_abs_out" )")

        # Debug ffmpeg cli args
        if [[ $debug_ffmpeg_args = true ]]; then
              print_ffmpeg_args "${vid_full_cmd[@]}"
        fi

        # Record start time and end time
        vid_enc_start_time=$( date +%s )
        echo -e "\e[90m[\e[36mstart\e[90m $( date +%X )]\e[0m"

        # Finally, run FFmpeg
        run_ffmpeg "$details" "${vid_full_cmd[@]}"
        encode_success=$?

        # Print end and duration
        vid_enc_end_time=$( date +%s )
        echo -e '\e[2K\r\e[90m[\e[36m'"ended\e[90m $( date +%X )]\e[0m ($( human_duration "$(( vid_enc_end_time - vid_enc_start_time ))" ))"

        if [[ $encode_success == 0 ]]; then
            # Remove original video after encoding
            if [[ $clean == true ]]; then
                echo "Deleting original video '$video'..."
                rm "$video"
            fi

            # Print FFmpeg errors even though it didn't fail
            if [[ $debug_ffmpeg_errors == true ]]; then
                # Print error log in grey and encode next video in queue
                echo -e '\n\e[33m'"Info:\e[0m FFmpeg error log:"
                echo -en '\e[37m'"$ffmpeg_last_error_log"'\e[0m'
            fi

            (( video_successful_count++ ))
        else
            if [[ $fatal == true ]]; then
                # Print error log in red and exit with non-zero error code
                echo -e '\n\e[91m'"Fatal:\e[0m FFmpeg failed with the following errors:"
                echo -e '\e[31m'"$ffmpeg_last_error_log"'\e[0m'
                echo "Aborting..."
                be_exit 1
            else
                # Print error log in grey and encode next video in queue
                echo -e '\n\e[33m'"Warning:\e[0m FFmpeg failed with the following errors:"
                echo -en '\e[37m'"$ffmpeg_last_error_log"'\e[0m'
            fi
        fi
    done
}

# Check if a video is "valid" by checking the last
# 10 seconds of a video for errors, and update the blacklist
# if it's invalid
watchmode_check_valid() {
    local video=$1
    local video_base64=$2
    local invalid=$( ( ffmpeg -v error -sseof -10 -i "$video" -f null - 1> /dev/null < /dev/null ) 2>&1 )
    [[ -z $invalid ]] # Make sure $invalid contains no errors from FFmpeg
    local is_valid=$?

    # Remove the line with invalid video and append a new one with
    # updated timestamp
    if [[ $is_valid != 0 ]]; then
        local invalid_linenr=$( grep -n -F "$video_base64" "$tmp_vid_enc_watch_invalid_list" )
        local invalid_linenr=${invalid_linenr%%:*}
        local invalid_list=$( sed -e "${invalid_linenr}d" < "$tmp_vid_enc_watch_invalid_list" )
        ( echo "$invalid_list"; echo "$SECONDS $video_base64" ) > "$tmp_vid_enc_watch_invalid_list"
    fi

    return $is_valid
}

# (During watchmode) check if a video was blacklisted as invalid, and if
# it was check if cooldown has passed. Succeeds if video wasn't blacklisted
# or if cooldown has passed.
watchmode_valid() {
    local video=$1
    local video_base64=$( base64 -w 0 <<< "$video" )
    local blacklisted_line=$( grep -F "$video_base64" "$tmp_vid_enc_watch_invalid_list" )

    if [[ -n $blacklisted_line ]]; then
        local time=${blacklisted_line%% *}

        if [[ "$time + $WATCH_INVALID_MAX_WAIT" -lt $SECONDS ]]; then
            watchmode_check_valid "$video" "$video_base64"
            return
        else
            return 1
        fi
    else
        watchmode_check_valid "$video" "$video_base64"
        return
    fi
}

# Start by either encoding then watching source directory for new videos or just
# encoding once
if [[ $watch == true ]]; then
    if ! which inotifywait 1> /dev/null 2>&1; then
        echo -e '\n'"Error: Watch mode requires $( b inotifywait )"
        be_exit 1
    fi

    # Get initial $videos
    find_source_videos
    processed_initial_videos=false
    last_iteration_encoding=false

    WATCH_MAX_WAIT=5 # in seconds
    WATCH_INVALID_MAX_WAIT=5 # in seconds
    watch_last_wait_time=$SECONDS
    watch_last_read_count=1
    watch_event_last_wait_time=$SECONDS

    # Default events to listen for (on Linux)
    inotify_event_args=(-e close_write -e moved_to)
    inotify_read_args=()

    # Empty array to make inotify listen to any and all events
    if [[ $watch_rescan == true ]]; then
        inotify_event_args=()
        inotify_read_args=(-t 5)
    fi

    # Startup inotifywait in the background
    # TODO: Phase out inotify in favor of polling on
    # platforms like WSL. It only serves as additional
    # overhead on those platforms with little or no gain.
    ( inotifywait -mr --format '%e %w%f' "${inotify_event_args[@]}" "${dir_sources[@]}" 2> /dev/null |
        while read "${inotify_read_args[@]}" event || true; do
            if [[ $watch_rescan == true ]]; then
                # Debounce
                if [[ "$watch_event_last_wait_time + $WATCH_MAX_WAIT" -lt $SECONDS ]]; then
                    # Since we're not in a reliable environment, run a dir
                    # scan on every inotify event
                    find_source_videos true

                    for video in "${videos[@]}"; do
                        cur_video_abs_path="$( readlink -f "$video" )"

                        # Add the video if it wasn't listed before
                        if ! grep -qF -e "$cur_video_abs_path" "$tmp_vid_enc_list"; then
                            if [[ $watch_validate == true ]]; then
                                # Check that the video is valid
                                if watchmode_valid "$cur_video_abs_path"; then
                                    echo "$cur_video_abs_path" >> "$tmp_vid_enc_list"

                                    # Add video to watch list to be caught by main
                                    # batch encoder process
                                    echo "$video" >> "$tmp_vid_enc_watch_list"
                                    echo -n "#" >> "$tmp_vid_enc_watch_sync"
                                fi
                            else
                                echo "$cur_video_abs_path" >> "$tmp_vid_enc_list"

                                # Add video to watch list to be caught by main
                                # batch encoder process
                                echo "$video" >> "$tmp_vid_enc_watch_list"
                                echo -n "#" >> "$tmp_vid_enc_watch_sync"
                            fi
                        fi
                    done

                    watch_event_last_wait_time=$SECONDS
                fi
            else
                # We're in a reliable environment (Linux) and can trust
                # inotify's file change events
                event_target=${event#* }
                event_type=$( grep -Eo '^[^ ]+' <<< "$event" )

                if [[ $event_target =~ .+\.(mkv|avi|mp4)$ ]]; then
                    if [[ $watch_validate == true ]]; then
                        cur_video_abs_path="$( readlink -f "$event_target" )"

                        # Check that the video is valid
                        if watchmode_valid "$cur_video_abs_path"; then
                            # We got a new (valid) file, add it to the list of videos
                            echo "$event_target" >> "$tmp_vid_enc_watch_list"
                            echo -n "#" >> "$tmp_vid_enc_watch_sync"
                        fi
                    else
                        # We got a new file, add it to the list of videos
                        echo "$event_target" >> "$tmp_vid_enc_watch_list"
                        echo -n "#" >> "$tmp_vid_enc_watch_sync"
                    fi
                fi
            fi
        done ) &

    # Watch for new files and encode them after the current encode (if any)
    # finishes
    while true; do
        # Process existing videos first before watching for new files.
        # Note that watching is still active, we just encode existing
        # videos first
        if [[ $processed_initial_videos == false ]]; then
            current_video_count=${#videos[@]}
            if [[ $current_video_count -gt 0 ]]; then
                process_videos
                start_encoding
            else
                echo "" # For empty line between searching and watching message
            fi

            processed_initial_videos=true
            last_iteration_encoding=true

            if [[ $watch_rescan == true ]]; then
                # Add processed videos to the list to skip
                # processing them again
                for video in "${videos[@]}"; do
                    readlink -f "$video" >> "$tmp_vid_enc_list"
                done
            fi

            # Empty video list and video detail list
            videos=()
            video_details=()
            continue
        else
            cur_watch_list=$(< "$tmp_vid_enc_watch_list")
            cur_watch_list_sync=$(< "$tmp_vid_enc_watch_sync")

            # Check if there are any newer videos listed
            if [[ "${#cur_watch_list_sync} + 1" -gt $watch_last_read_count ]]; then
                while read -r new_video_file; do
                    videos+=("$new_video_file")

                    # Increase last read video count
                    (( watch_last_read_count++ ))
                done <<< "$( sed -nEe "$watch_last_read_count,\$p" <<< "$cur_watch_list" )"

                # Reset timer after getting new videos
                watch_last_wait_time=$SECONDS
            else
                # We didn't get any new videos. Check if wait time has
                # elapsed so we can start encoding the new files that we
                # do have (if any)
                if [[ $SECONDS -gt "$watch_last_wait_time + $WATCH_MAX_WAIT" ]]; then
                    # Check if any new videos were discovered and encode them
                    if [[ ${#videos[@]} -gt 0 ]]; then
                        process_videos " while watching"
                        start_encoding
                        last_iteration_encoding=true

                        # Empty video list and video detail list
                        videos=()
                        video_details=()
                        watch_last_wait_time=$SECONDS
                        continue
                    fi

                    # Reset timer waiting for new videos
                    watch_last_wait_time=$SECONDS
                fi
            fi
        fi

        if [[ $last_iteration_encoding == true ]]; then
            echo -e '\n\e[92m'"$( b "Watching for new videos..." )\n"
        fi

        last_iteration_encoding=false
        sleep 1
    done
else
    # Just encode once without watching
    find_source_videos
    process_videos
    start_encoding

    echo -e "\n\e[92mEncoded $video_successful_count videos successfully\e[0m"
fi

if [[ $watch == false ]]; then
    # Clean up temporary files
    cleanup 1
fi

