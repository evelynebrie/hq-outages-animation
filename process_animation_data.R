#!/usr/bin/env Rscript
# Process polygon data for time-based animation

suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(jsonlite)
  library(lubridate)
})

cat("=== HQ Outages Animation Data Processor ===\n\n")

# Configuration
dropbox_token <- Sys.getenv("DROPBOX_TOKEN")
weeks_to_process <- as.integer(Sys.getenv("WEEKS_TO_PROCESS", "4"))
output_dir <- "public/data"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

cat(sprintf("Processing last %d weeks of data\n\n", weeks_to_process))

# ==================================================================
# STEP 1: List files from Dropbox
# ==================================================================
cat("[1] Listing polygon files from Dropbox...\n")

list_files <- function() {
  all_files <- character()
  has_more <- TRUE
  cursor <- ""

  while (has_more) {
    if (cursor == "") {
      response <- system2("curl", c(
        "-s", "-X", "POST",
        "https://api.dropboxapi.com/2/files/list_folder",
        "-H", sprintf("Authorization: Bearer %s", dropbox_token),
        "-H", "Content-Type: application/json",
        "-d", '{"path": "/hq-outages", "recursive": true}'
      ), stdout = TRUE)
    } else {
      response <- system2("curl", c(
        "-s", "-X", "POST",
        "https://api.dropboxapi.com/2/files/list_folder/continue",
        "-H", sprintf("Authorization: Bearer %s", dropbox_token),
        "-H", "Content-Type: application/json",
        "-d", sprintf('{"cursor": "%s"}', cursor)
      ), stdout = TRUE)
    }

    response_json <- fromJSON(paste(response, collapse = "\n"))

    if (!is.null(response_json$entries)) {
      files <- response_json$entries$path_display[response_json$entries$".tag" == "file"]
      polygon_files <- grep("polygons_.*\\.geojson$", files, value = TRUE)
      all_files <- c(all_files, polygon_files)
    }

    has_more <- response_json$has_more
    cursor <- ifelse(has_more, response_json$cursor, "")
  }

  all_files
}

all_files <- list_files()
cat(sprintf("  Found %d polygon files\n", length(all_files)))

# ==================================================================
# STEP 2: Parse timestamps and filter recent weeks
# ==================================================================
cat("\n[2] Filtering recent weeks...\n")

# Extract timestamps from filenames
parse_timestamp <- function(filename) {
  pattern <- "polygons_(\\d{8})T(\\d{6})\\.geojson"
  matches <- regmatches(basename(filename), regexec(pattern, basename(filename)))
  if (length(matches[[1]]) < 3) return(NA)

  date_str <- matches[[1]][2]
  time_str <- matches[[1]][3]

  datetime_str <- sprintf("%s-%s-%s %s:%s:%s",
                         substr(date_str, 1, 4),
                         substr(date_str, 5, 6),
                         substr(date_str, 7, 8),
                         substr(time_str, 1, 2),
                         substr(time_str, 3, 4),
                         substr(time_str, 5, 6))
  as.POSIXct(datetime_str, tz = "UTC")
}

file_data <- data.frame(
  path = all_files,
  timestamp = sapply(all_files, parse_timestamp),
  stringsAsFactors = FALSE
)

file_data <- file_data[!is.na(file_data$timestamp), ]
file_data <- file_data[order(file_data$timestamp, decreasing = TRUE), ]

# Filter to recent weeks
cutoff_date <- max(file_data$timestamp) - weeks(weeks_to_process)
file_data <- file_data[file_data$timestamp >= cutoff_date, ]

cat(sprintf("  Filtered to %d files from last %d weeks\n", nrow(file_data), weeks_to_process))
cat(sprintf("  Date range: %s to %s\n",
            min(file_data$timestamp), max(file_data$timestamp)))

# ==================================================================
# STEP 3: Group files by week
# ==================================================================
cat("\n[3] Grouping files by week...\n")

file_data$week_start <- floor_date(file_data$timestamp, "week", week_start = 1) # Monday

weeks <- unique(file_data$week_start)
weeks <- sort(weeks, decreasing = TRUE)

cat(sprintf("  Processing %d weeks\n", length(weeks)))

# ==================================================================
# STEP 4: Process each week
# ==================================================================
cat("\n[4] Processing weekly data...\n")

for (week_start in weeks) {
  week_start_dt <- as.POSIXct(week_start, origin = "1970-01-01", tz = "UTC")
  week_end_dt <- week_start_dt + days(7)
  week_label <- format(week_start_dt, "%Y-%m-%d")

  cat(sprintf("\n  Week: %s to %s\n", week_label, format(week_end_dt - days(1), "%Y-%m-%d")))

  week_files <- file_data[file_data$week_start == week_start, ]
  cat(sprintf("    Files: %d\n", nrow(week_files)))

  # Download and combine polygons for this week
  all_features <- list()

  for (i in 1:min(nrow(week_files), 672)) { # Max 7 days * 96 = 672 files
    file_path <- week_files$path[i]
    timestamp <- week_files$timestamp[i]

    if (i %% 50 == 0) {
      cat(sprintf("      Processing file %d/%d...\n", i, nrow(week_files)))
    }

    # Download file
    temp_file <- tempfile(fileext = ".geojson")
    system2("curl", c(
      "-s", "-X", "POST",
      "https://content.dropboxapi.com/2/files/download",
      "-H", sprintf("Authorization: Bearer %s", dropbox_token),
      "-H", sprintf('Dropbox-API-Arg: {"path": "%s"}', file_path),
      "-o", temp_file
    ), stdout = FALSE, stderr = FALSE)

    # Read GeoJSON
    tryCatch({
      geojson_data <- st_read(temp_file, quiet = TRUE)

      if (nrow(geojson_data) > 0) {
        # Convert to list format for JSON
        features <- lapply(1:nrow(geojson_data), function(j) {
          geom <- st_geometry(geojson_data[j, ])
          coords <- st_coordinates(geom)

          # Handle MULTIPOLYGON
          if (st_geometry_type(geom) == "MULTIPOLYGON") {
            # Simplify to first polygon for animation
            coords_list <- list(list(coords[, 1:2]))
          } else {
            coords_list <- list(coords[, 1:2])
          }

          list(
            type = "Feature",
            properties = list(
              timestamp = format(timestamp, "%Y-%m-%d %H:%M:%S")
            ),
            geometry = list(
              type = "Polygon",
              coordinates = coords_list
            )
          )
        })

        all_features <- c(all_features, features)
      }
    }, error = function(e) {
      cat(sprintf("      Warning: Failed to read %s\n", basename(file_path)))
    })

    unlink(temp_file)
  }

  # Create GeoJSON for this week
  week_geojson <- list(
    type = "FeatureCollection",
    features = all_features,
    metadata = list(
      week_start = format(week_start_dt, "%Y-%m-%d"),
      week_end = format(week_end_dt - days(1), "%Y-%m-%d"),
      file_count = length(all_features),
      generated = format(Sys.time(), "%Y-%m-%d %H:%M:%S")
    )
  )

  output_file <- file.path(output_dir, sprintf("week_%s.json", week_label))
  write_json(week_geojson, output_file, auto_unbox = TRUE, pretty = FALSE)

  file_size_mb <- file.size(output_file) / 1024 / 1024
  cat(sprintf("    ✓ Saved: %s (%.1f MB, %d features)\n",
              basename(output_file), file_size_mb, length(all_features)))
}

# ==================================================================
# STEP 5: Create week index
# ==================================================================
cat("\n[5] Creating week index...\n")

week_index <- data.frame(
  week_start = format(weeks, "%Y-%m-%d"),
  week_end = format(weeks + days(6), "%Y-%m-%d"),
  file = sprintf("week_%s.json", format(weeks, "%Y-%m-%d")),
  stringsAsFactors = FALSE
)

write_json(week_index, file.path(output_dir, "weeks.json"), pretty = TRUE)
cat(sprintf("  ✓ Index saved with %d weeks\n", nrow(week_index)))

cat("\n✅ Processing complete!\n")
cat(sprintf("   Generated %d week files in %s/\n", nrow(week_index), output_dir))
