#!/bin/bash

# Author: Mike32
#
# Print usage: encoder.sh -h
#
# This works in any *nix environment with at least Bash v4 
# and `ffmpeg` and `ffprobe` are in your PATH
#
# It also works on Windows via WSL as long as both `ffmpeg.exe` and 
# `ffprobe.exe` are in your PATH

# TODO: Add watch feature to watch the source folder for new files
# TODO: Check screen width everytime you print
# TODO: Don't erase line when printing progress, just padd the rest of the line with spaces
# TODO: Batch video resolution (e.g 1080,720,360)
# TODO: Cache FFprobe's output somewhere
# TODO: Print FFmpeg errors _after_ the progress _while_ still updating process _in-place_
# TODO: Remove ./ from the beginning of paths
# TODO: Validate stream options

shopt -s extglob
shopt -u nocaseglob

# Utility functions

# Bold formatting
b() {
    echo -en "\e[1m$1\e[0m"
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
    key="$1"
    details="$2"

    echo "$details" | grep -E "^$key:" | sed -Ee 's/^[^:]+:(.*)$/\1/'
}

# Convert paths for external Windows programs
HAS_CYGPATH=false
HAS_WSLPATH=false

path() {
    __cur_path="$1"

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
    __cur_path="$1"

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

# Human readable duration
human_duration() {
    local seconds="$1"
    local output=""

    # Hours
    if [[ $seconds -gt $(( 60 * 60 )) ]]; then
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

    shift
    local ffmpeg_cmd=("${@}")

    # Mapping of stream id's to video stream frame counts and duration
    IFS=':'
    declare -A vid_stream_frames
    for vid_s_frames in $vid_frames; do
        local vid_stream_info_acts=(stream_id frames duration)
        local stream_id=
        local cur_vid_stream_frames=
        local cur_vid_stream_duration=

        IFS=','
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
    "${ffmpeg_cmd[@]}" | 
        while read line; do
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
                if [[ $( printf "%.f" "${cur_progress[fps]}" ) -gt 0 ]]; then
                    local eta_secs="$( printf "%.f" "$( bc <<< "scale=8; ($enc_frame_count - ${cur_progress[frame]}) / ${cur_progress[fps]}" )" )"
                else
                    local eta_secs=0
                fi

                # Get terminal's columns/width
                local columns=$( tput cols )

                # Print progress, FPS, and ETA (with some pretty formatting)
                echo -en "Progress \e[92m$( b "$enc_pct" ) FPS $( b "${cur_progress[fps]}" ) ETA $( b "$( human_duration "$eta_secs" )" )"
                local printed_message="Progress $enc_pct FPS ${cur_progress[fps]} ETA $( human_duration "$eta_secs" )"
                local printed_message_length=${#printed_message}

                # Clear line
                local full_line="$( dd bs=1 count=$(( columns - printed_message_length )) if=/dev/zero 2> /dev/null | tr '\0' ' ' )"
                echo -en "\e[0K${full_line}\r"
            else
                local cur_progress[$key]="$value"
            fi
        done

    local ffmpeg_status=$?

    # Get terminal's columns/width
    local columns=$( tput cols )

    # Clear line
    local full_line="$( dd bs=1 count=$columns if=/dev/zero 2> /dev/null | tr '\0' ' ' )"
    echo -en "\e[0K\r${full_line}"

    # Show cursor
    echo -en "\e[?25h"

    # Return FFmpeg's exit status
    return $ffmpeg_status
}

# Main script logic

# Print usage/help
usage() {
    cat <<EOF
USAGE
    encoder [sub | dub] [-r RES] [-a] [-s SOURCE] [-d DEST] [-R]
            [--burn-subs] [--watermark FILE] [--clean] [--force]
    encoder -h | --help

DESCRIPTION
    Encode all MKV and AVI videos in the current
    directory (or subdirectories) to MP4 videos.
    Options are either set via optional arguments
    listed below or interactive prompts in the
    absence of such arguments.

OPTIONS
    sub dub
        Whether to encode subbed or dubbed.
        Defaults to subbed.

    -r --resolution RES
        RES can be one of $( b 240 ), $( b 360 ), $( b 480 ), $( b 640 ), $( b 720 ),
        $( b 1080 ), or $( b original ). Original by default.

    -a --auto --no-auto
        Automatically determine appropriate audio
        and video streams. Implies --burn-subs
        in the absence of --no-burn-subs. Prompts
        by default.

    --burn-subs --no-burn-subs
        Burn subtitles. Prompts by default.

    --watermark FILE --no-watermark
        Use a watermark .ass FILE. Defaults to
        AU watermark if it exists.

    -s --source DIR
        Source directory for encodes. Defaults to
        current directory.

    -d --destination DIR
        Destination directory for all encodes.
        Will create the directory it it doesn't
        already exist. Defaults to source
        directory.

    -R --recursive
        Whether to recursively search subdirs for
        videos to encode. Won't by default.

    --clean
        Remove original videos after encoding.

    --force
        Overwrite existing videos. Won't by default.

    --debug-run [DURATION]
        Test encoder by only encoding (optional) 
        DURATION in seconds of videos. When 
        DURATION is omitted it defaults to 5
        seconds.

    -h --help
        Show this help.
EOF
}

# Data dir with watermark (same as script folder)
data_dir="$(dirname $(realpath "${BASH_SOURCE[0]}"))"

# Some defaults
declare -A defaults
declare -A arg_mapping

defaults[res]=prompt                   # Default resolution (same as source)
defaults[auto]=null                    # Automatically determine streams
defaults[src_dir]=.                    # Source directory
defaults[out_dir]=null                 # Output directory
defaults[recursive]=null               # Recursively encode subdirs
defaults[force]=false                  # Overwrites existing encodes
defaults[clean]=false                  # Removes original video after encoding
defaults[burn_subs]=null               # Burns subtitles into videos
defaults[watermark]="$data_dir/au.ass" # Watermark video (with AU watermark by default)
defaults[locale]=sub                   # Subbed or dubbed
defaults[debug_run]=false              # Only encode short durations of the video for testing
defaults[debug_run_dur]=5              # Debug run duration

arg_mapping[-r]=--resolution
arg_mapping[-a]=--auto
arg_mapping[-d]=--destination
arg_mapping[-s]=--source
arg_mapping[-R]=--recursive
arg_mapping[-h]=--help

cur_arg="$1"
consume_next=false
consume_optional=false
consume_next_arg=

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

            defaults[$consume_next_arg]="$cur_arg"

            consume_next=false
            consume_optional=false
        # Current arg isn't another arg's parameter
        else
            cur_base_arg=("$cur_arg")
            cur_base_arg_index=0

            while [[ -n ${cur_base_arg[$cur_base_arg_index]} ]]; do
                case ${cur_base_arg[$cur_base_arg_index]} in
                    # Match all (listed) single char arguments either combined
                    # (e.g -aRs) or separate (e.g -a -R -s)
                    -+([adhsRr]) )
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
                        consume_next_arg=src_dir
                        ;;
                    --recursive )
                        defaults[recursive]=true
                        ;;
                    --force )
                        defaults[force]=true
                        ;;
                    --clean )
                        defaults[clean]=true
                        ;;
                    --debug-run )
                        defaults[debug_run]=true

                        # Debug run's duration is (optionally) supplied as next arg
                        consume_next=true
                        consume_optional=true
                        consume_next_arg=debug_run_dur
                        ;;
                    --help )
                        # Print help and quit
                        usage
                        exit 0
                        ;;

                    # Sub/dub
                    dub )
                        defaults[locale]=dub
                        ;;
                    * )
                        : # Nothing to do NOTE: Likely pointless
                esac

                (( cur_base_arg_index++ ))
            done
        fi
    fi

    # Process next arg
    shift && cur_arg="$1" || break
done

# Deconstruct default variables
res="${defaults[res]}"
auto="${defaults[auto]}"
out_dir="${defaults[out_dir]}"
src_dir="${defaults[src_dir]}"
recursive="${defaults[recursive]}"
force="${defaults[force]}"
clean="${defaults[clean]}"
burn_subs="${defaults[burn_subs]}"
watermark="${defaults[watermark]}"
locale="${defaults[locale]}"
debug_run="${defaults[debug_run]}"
debug_run_dur="${defaults[debug_run_dur]}"

# Default output dir to src dir
if [[ $out_dir == null ]]; then
    out_dir="$src_dir"
fi

# Validate resolution variable
case $res in 
    240* | 360* | 480* | 720* | 1080* )
        res=$( echo "$res" | grep -oE '^(240|360|480|720|1080)' )
        ;;
    original | prompt )
        :
        ;;
    * )
        usage
        echo -e "\nInvalid resolution '$res'"
        exit 1
esac

# Check for (optional) Watermark file
use_watermark=true

if [[ ! -f "$watermark" ]]; then
    if [[ -n "$watermark" ]]; then
        echo "Notice: Watermark '$watermark' doesn't exist"
    fi
    use_watermark=false
fi

# Find FFmpeg executable
ffmpeg_executable=$( which ffmpeg )
ffprobe_executable=$( which ffprobe )
IS_WINDOWS=false

# Check for Windows FFmpeg in WSL if we haven't found a *nix
# installed build
if [[ -z $ffmpeg_executable ]]; then
    ffmpeg_executable=$( which ffmpeg.exe )
    ffprobe_executable=$( which ffprobe.exe )
    IS_WINDOWS=true
fi

if [[ -z $ffmpeg_executable ]]; then
    echo "FFmpeg command not installed in your PATH, aborting..."
    exit 1
fi

if [[ -z $ffprobe_executable ]]; then
    echo "FFprobe command not installed in your PATH, aborting..."
    exit 1
fi

# If we're running Windows make sure we have a win 2 *nix path converter around
if [[ $IS_WINDOWS == true ]]; then
    # Check for either wslpath or cygpath
    if which wslpath 2>&1 > /dev/null; then
        HAS_WSLPATH=true
    elif which cygpath 2>&1 > /dev/null; then
        HAS_CYGPATH=true
    else
        echo "On Windows either 'wslpath' or 'cygpath.exe' is required."
        exit 1
    fi

    # Check for Windows paths provided by the user in either `-s` or `-d`
    check_windows_path() {
        local path="$1"

        # Match against absolute paths on Windows
        if [[ $path =~ [A-Z]:\\ ]]; then
            nix_path "$path"
        else
            echo -n "$path"
        fi
    }

    src_dir="$( check_windows_path "$src_dir" )"
    out_dir="$( check_windows_path "$out_dir" )"
fi

echo "Found FFmpeg: $ffmpeg_executable"
echo "Found FFprobe: $ffprobe_executable"

if [[ $ffmpeg_executable =~ ".exe" ]]; then
    if ! which wslpath 2>&1 > /dev/null; then
        echo "WSLpath command not installed in your PATH, aborting..."
        exit 1
    else
        echo "Found WSLPath: $( which wslpath )"
    fi
fi

# Grab all source videos
videos=()
IFS=$'\n'
shopt -s nocaseglob

if [[ $recursive == true ]]; then
    echo -e "\nSearching recursively for video sources..."
    curdir_files="$( cd "$src_dir"; ls -1 )"

    for file in $curdir_files; do
        if [[ -d "$src_dir/$file" ]]; then
            curdir_videos="$( cd "$src_dir/$file"; ls -1 *.{mkv,avi} 2> /dev/null )"
            for video in $curdir_videos; do
                videos+=("$file/$video")
            done
        fi
    done
else
    echo -e "\nSearching current directory for video sources..."
    curdir_videos="$( cd "$src_dir"; ls -1 *.{mkv,avi} 2> /dev/null )"

    for video in $curdir_videos; do
        videos+=("$video")
    done
fi

# Exit if no videos found
if [[ ${#videos[@]} == 0 ]]; then
    echo "No videos found"
    exit 0
fi

video_details=()
video_count=${#videos[@]}
echo "Found $video_count videos"
echo -e "\n\e[95m\e[1mProcessing videos...\e[0m"

# Gather preliminary information about the videos
cur_video_index=1
for video in ${videos[@]}; do
    vid_dir="$( dirname "$video" )"
    vid_file="$( basename "$video" )"
    echo -e "\nProcessing [$cur_video_index/$video_count] \e[32m$vid_dir/\e[92m$vid_file\e[0m..."

    streams=
    vid_out="$vid_dir/${vid_file%.*}.mp4"
    cur_vid_auto=$auto
    cur_vid_details=
    video_stream=
    audio_stream=
    vid_burn_subs=$burn_subs

    if [[ $cur_vid_auto == null ]]; then
        confirm "Find streams automatically?" "y" && cur_vid_auto=true
    fi

    # Get list of all streams
    streams=$( "$ffprobe_executable" "$( path "$src_dir/$video" )" 2>&1 ) # | grep 'Stream #0' )

    # Duration line is independent of streams
    vid_duration_line=$( echo -n "$streams" | grep "Duration: " )

    # Get all video streams' (estimated) frame counts
    vid_video_streams="$( echo "$streams" | grep 'Stream #0' | grep " Video" )"
    cur_vid_vid_streams=()
    cur_vid_stream=1

    # Loop all possible video streams
    while true; do
        cur_vid_stream_details="$( echo "$vid_video_streams" | sed -ne "${cur_vid_stream},0p" )"

        # No more streams to process
        [[ -z $cur_vid_stream_details ]] && break

        vid_stream_framecount="$( get_stream_framecount "$( echo -en "$vid_duration_line\n$cur_vid_stream_details" )" )"
        cur_vid_vid_streams+=("$vid_stream_framecount")

        (( cur_vid_stream++ ))
    done

    # Determine streams either automatically or by prompt
    if [[ $cur_vid_auto == true ]]; then
        # Burns subs automatically too (mirroring Meow's original script)
        [[ $vid_burn_subs == null ]] && vid_burn_subs=true
    else
        # Print streams human-readable
        echo "$streams" | grep 'Stream #0' | sed -Ee 's/Stream #0:([0-9]+):/Stream \1 ->/' -e 's/Stream #0:([0-9]+)([^:]+): ([^:]+)/Stream \1 -> \3 \2/' -e 's/(Video|Audio|Subtitle|Attachment)/\x1B[1m\1\x1B[0m/'

        echo -n "Select Video: "
        read video_stream
        echo -n "Select Audio: "
        read audio_stream

        video_stream=$( echo "$video_stream" | sed -Ee 's/^\s*([0-9]+).*/\1/' )
        audio_stream=$( echo "$audio_stream" | sed -Ee 's/^\s*([0-9]+).*/\1/' )
    fi

    # Detect subtitle streams
    cur_vid_has_subtitles=true

    if [[ -z "$( grep -E "Stream #.+Subtitle" <<< "$streams" )" ]]; then
        cur_vid_has_subtitles=false
    fi

    if [[ $vid_burn_subs == null ]]; then
        if [[ $cur_vid_has_subtitles == true ]]; then
            confirm "Burn subtitles?" "n" && vid_burn_subs=true
        else
            echo "No subtitles detected"
        fi
    fi

    # No matter the settings, disable burning subtitles for this
    # video since it doesn't have any subtitles
    if [[ $cur_vid_has_subtitles == false ]]; then
        vid_burn_subs=false
    fi

    IFS=':'
    # Save video details' struct
    cur_vid_details=$(cat <<VID
VIDEO:$video
VIDEO_OUT:$vid_out
AUTO:$cur_vid_auto
VSTREAM:$video_stream
ASTREAM:$audio_stream
VSTREAM_FRAMES:${cur_vid_vid_streams[*]}
BURNSUBS:$vid_burn_subs
VID
)

    video_details+=("$cur_vid_details")
    (( cur_video_index++ ))
done

# Required FFmpeg args
ffmpeg_input_args=(
    -hide_banner
    -loglevel warning
    -strict -2        # In case old version of FFmpeg to enable experimental AAC encoder
)

ffmpeg_output_args=(
    -y                # Overwrite existing files without prompting, we check instead
    -c:v libx264
    -preset faster
    -tune animation
    -crf 23
    -profile:v high
    -level 4.1
    -pix_fmt yuv420p
    -c:a aac
    -b:a 192k
    -movflags faststart # Web optimization
)

# Only encode 5 seconds for debugging
if [[ $debug_run == true ]]; then
    ffmpeg_output_args+=(-t $debug_run_dur)
fi

echo -e "\n\e[95m\e[1mEncoding videos...\e[0m"

# Start encoding videos with information gathered from previous step
cur_video_index=0
for details in "${video_details[@]}"; do
    (( cur_video_index++ ))
    video="$( get_detail "VIDEO" "$details" )"
    video_out="$( get_detail "VIDEO_OUT" "$details" )"
    vid_auto="$( get_detail "AUTO" "$details" )"
    video_stream="$( get_detail "VSTREAM" "$details" )"
    audio_stream="$( get_detail "ASTREAM" "$details" )"
    vid_burn_subs="$( get_detail "BURNSUBS" "$details" )"
    vid_res=$res

    vid_abs_out="$out_dir/$video_out"
    vid_abs_out_dir="$( dirname "$vid_abs_out" )"

    # Initialize video filters with watermark (if it exists)
    if [[ $use_watermark == true ]]; then
        vid_filter_args=("ass=\\'$( path "$watermark" )\\'")
    else
        vid_filter_args=()
    fi

    # Make local copy of ffmpeg output args
    vid_output_args=("${ffmpeg_output_args[@]}")

    # Major video path components split for formatting purposes
    vid_dir="$( dirname "$video" )"
    vid_file="$( basename "$video" )"
    vid_out_dir="$( dirname "$video_out" )"
    vid_out_file="$( basename "$video_out" )"

    # Skip video if it exists and force(fully overwriting) isn't enabled
    if [[ $force != true ]] && [[ -f "$vid_abs_out" ]]; then
        echo -e "\nSkipping [$cur_video_index/$video_count] \e[32m$vid_dir/\e[92m$vid_file\e[0m..."
        continue
    fi

    # Choose different streams instead of the defaults
    if [[ -n $video_stream ]] && [[ -n $audio_stream ]]; then
        vid_output_args+=(-map 0:$video_stream -map 0:$audio_stream)
    fi

    # Burn subs
    if [[ $vid_burn_subs == true ]]; then
        vid_filter_args+=("subtitles='$( path "$src_dir/$video" )'")
    fi

    # Create output dir if it doesn't exist already
    if [[ ! -d "$vid_abs_out_dir" ]]; then
        mkdir -p "$vid_abs_out_dir"
        successfully_created_dir=$?

        if [[ $successfully_created_dir != 0 ]]; then
            echo -e "\e[91mFatal:\e[0m Couldn't create output dir '$vid_abs_out_dir', aborting..."
            exit 1
        fi
    fi

    # Everything checks out, time to start encoding
    echo -e "\nEncoding [$cur_video_index/$video_count] \e[32m$vid_out_dir/\e[92m$vid_out_file\e[0m"
    echo -e   "    from \e[90m$vid_dir/$vid_file\e[0m"

    # Check if video resolution is specified by user or automatic
    [[ $vid_res == prompt ]] && vid_res=original

    if [[ $vid_res != original ]]; then
        # -1 and -2 maintain aspect ratio, but -2 will be divisible by 2 (and thus suitable for mp4/YUV 4:2:0)
        # Grabbed from here: https://stackoverflow.com/a/29582287
        vid_filter_args+=("scale=-2:$vid_res")
    fi

    # Append video filter args to output args
    IFS=","
    vid_output_args+=(-vf "${vid_filter_args[*]}")

    # Print progress to stdout
    vid_output_args+=(-progress pipe:1)

    # Record start time and end time
    vid_enc_start_time=$( date +%s )
    echo -e "\e[90m[\e[36mstart\e[90m $( date +%X )]\e[0m"

    # Finally, run FFmpeg
    vid_full_cmd=("$ffmpeg_executable" "${ffmpeg_input_args[@]}" -i "$( path "$src_dir/$video" )" "${vid_output_args[@]}" "${ffmpeg_size[@]}" "$( path "$vid_abs_out" )")
    run_ffmpeg "$details" "${vid_full_cmd[@]}"
    encode_success=$?

    # Print end and duration
    vid_enc_end_time=$( date +%s )
    echo -e "\r\e[90m[\e[36mended\e[90m $( date +%X )]\e[0m ($( human_duration "$(( vid_enc_end_time - vid_enc_start_time ))" ))"

    if [[ $encode_success == 0 ]]; then
        # Remove original video after encoding
        if [[ $clean == true ]]; then
            echo "Deleting original video '$src_dir/$video'..."
            rm "$src_dir/$video"
        fi
    else
        echo -e "\n\e[91mFatal:\e[0m FFmpeg failed, aborting..."
        exit 1
    fi
done

echo -e "\n\e[92mEncoded $video_count videos successfully\e[0m"

