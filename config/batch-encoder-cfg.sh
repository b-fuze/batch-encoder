#!/bin/bash

# Save as ~/.config/batch-encoder-cfg.sh
# This uses Bash Config syntax. Normal bash commands are invalid syntax.

# Note: Try to only uncomment the configurations you need

# defaults[res]=prompt                   # Default resolution (same as source)
# defaults[auto]=null                    # Automatically determine streams
# defaults[src_dir]=.                    # Source directory
# defaults[out_dir]=null                 # Output directory
# defaults[recursive]=null               # Recursively encode subdirs
# defaults[force]=false                  # Overwrites existing encodes
# defaults[watch]=false                  # Watch source directory for new videos
# defaults[watch_rescan]=false           # Rescan the source dir for every inotify event
# defaults[watch_validate]=false         # Validate last 10 seconds of files after detecting them from watch mode
# defaults[clean]=false                  # Removes original video after encoding
# defaults[burn_subs]=null               # Burns subtitles into videos
# defaults[recolor_subs]=false           # Recolor subtitles to a neutral color
# defaults[watermark]="$data_dir/au.ass" # Watermark video (with AU watermark by default)
# defaults[locale]=sub                   # Subbed or dubbed
# defaults[framerate]=original           # Framerate
# defaults[debug_run]=false              # Only encode short durations of the video for testing
# defaults[debug_run_dur]=5              # Debug run duration
# defaults[debug_ffmpeg_errors]=false    # Don't remove FFmpeg error logs
# defaults[fatal]=false                  # Fail on FFmpeg errors
# defaults[verbose_streams]=false        # Don't filter video, audio, and subs streams, also print e.g attachment streams
# defaults[help_section]=""              # Help section to choose from: basic, advanced, debug, all

# # Required FFmpeg args
# ffmpeg_input_args=(
#     -hide_banner
#     -loglevel warning
#     -strict -2        # In case old version of FFmpeg to enable experimental AAC encoder
# )

# ffmpeg_output_args=(
#     -y                # Overwrite existing files without prompting, we check instead
#     -c:v libx264 
#     -preset faster 
#     -tune animation 
#     -trellis 2 
#     -subq 10 
#     -me_method umh 
#     -crf 26.5 
#     -profile:v high 
#     -level 4.1 
#     -pix_fmt yuv420p 
#     -c:a aac 
#     -b:a 192k
#     -movflags faststart # Web optimization
# )

