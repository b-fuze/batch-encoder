#!/bin/bash

# Save as ~/.config/batch-encoder-cfg.sh
# This uses Bash Config syntax. Normal bash commands are invalid syntax.

# Note: Only uncomment what you want to change by removing the first # (hash) at
# the beginning of the line

# Uncomment this array variable to set default sources
# that are always encoded by batch encoder.
#
# default_sources=(
#   "/some/video/folder"
#   "/some/video.mkv"
# )

# defaults[framerate]=original           # Output framerate
# defaults[res]=prompt                   # Default resolution (same as source)
# defaults[auto]=null                    # Automatically determine streams
# defaults[keep_default_sources]=false   # If sources are specified don't omit the default sources
# defaults[out_dir]=""                   # Output directory
# defaults[recursive]=null               # Recursively encode subdirs
# defaults[out_suffix]=false             # Append a suffix to output filename
# defaults[out_suffix_name]=""           # Output filename suffix
# defaults[force]=false                  # Overwrites existing encodes
# defaults[watch]=false                  # Watch source directory for new videos
# defaults[watch_rescan]=false           # Rescan the source dir for every inotify event
# defaults[watch_validate]=false         # Validate last 10 seconds of files after detecting them from watch mode
# defaults[clean]=false                  # Removes original video after encoding
# defaults[burn_subs]=null               # Burns subtitles into videos
# defaults[recolor_subs]=false           # Recolor subtitles to a neutral color
# defaults[watermark]="$data_dir/au.ass" # Watermark video (with AU watermark by default)
# defaults[locale]=null                  # Subbed or dubbed. Set to either `sub` or `dub` without quotes to change the default. Implies `auto`
# defaults[target_lang]=en               # Target language to encode videos to
# defaults[origin_lang]=jp               # Original language videos (or streams of interest thereof) were encoded in
# defaults[debug_run]=false              # Only encode short durations of the video for testing
# defaults[debug_run_dur]=5              # Debug run duration
# defaults[debug_ffmpeg_errors]=false    # Don't remove FFmpeg error logs
# defaults[debug_ffmpeg_args]=false      # Print FFmpeg cli args
# defaults[fatal]=false                  # Fail on FFmpeg errors
# defaults[verbose_streams]=false        # Don't filter video, audio, and subs streams, also print e.g attachment streams
# defaults[prompt_all]=false             # Prompt for all videos, even ones with identical stream structures
# defaults[edit_config_editor]=""        # Default editor for edit-config command. If omitted is Vim on *nix and Notepad on Windows

# # FFmpeg argument defaults
# ffmpeg_input_args=(
#     -hide_banner
#     -loglevel warning
#     -strict -2        # In case old version of FFmpeg to enable experimental AAC encoder
# )

# ffmpeg_output_args=(
#     -y                # Overwrite existing files without prompting, we check instead
#     -c:v libx264
#     -preset veryslow
#     -tune ssim,fastdecode,zerolatency
#     -trellis 2
#     -subq 11
#     -me_method umh
#     -crf 19
#     -vsync 2
#     -g 30
#     -x264-params ref=6:deblock=1,1:bframes=8:psy-rd=1.5:aq-mode=3:aq-strength=1:psy-rd=1.50,0.60
#     -profile:v high
#     -level 4.1
#     -b_strategy 1
#     -bf 16
#     -color_primaries bt709
#     -color_trc bt709
#     -colorspace bt709
#     -pix_fmt yuv420p
#     -c:a aac
#     -ac 2
#     -b:a 192k
#     -sn
#     -map_metadata -1
#     -map_chapters -1
#     -movflags +faststart # Web optimization
# )

