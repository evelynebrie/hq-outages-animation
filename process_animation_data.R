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
days_to_process <- as.integer(Sys.getenv("DAYS_TO_PROCESS", "1"))
output_dir <- "public/data"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

cat(sprintf("Processing last %d day(s) of data\n\n", days_to_process))

# ==================================================================
# STEP 1: List files from Dropbox
# ==================================================================
cat("[1] Listing polygon files from Dropbox...\n")

# Debug: List root folder first
cat("DEBUG: Listing root folder to see what's accessible...\n")
root_response <- system2("curl", c(
  "-s", "-X", "POST",
  "https://api.dropboxapi.com/2/files/list_folder",
  "-H", sprintf("Authorization: Bearer %s", dropbox_token),
  "-H", "Content-Type: application/json",
  "-d", '{"path": "", "recursive": false}'
), stdout = TRUE)
cat("Root folder contents:\n", paste(root_response, collapse="\n"), "\n\n")

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

    # Debug: print raw response
    cat("DEBUG - Raw API response:\n")
    cat(paste(response, collapse = "\n"), "\n")
    cat("DEBUG - Response length:", length(response), "\n\n")

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
# STEP 2: Parse timestamps and filter recent days
# ==================================================================
cat("\n[2] Filtering recent days...\n")

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

# Filter to recent days
cutoff_date <- max(file_data$timestamp) - days(days_to_process)
file_data <- file_data[file_data$timestamp >= cutoff_date, ]

cat(sprintf("  Filtered to %d files from last %d day(s)\n", nrow(file_data), days_to_process))
cat(sprintf("  Date range: %s to %s\n",
            min(file_data$timestamp), max(file_data$timestamp)))

# ==================================================================
# STEP 3: Group files by day
# ==================================================================
cat("\n[3] Grouping files by day...\n")

file_data$day_start <- floor_date(file_data$timestamp, "day")

days <- unique(file_data$day_start)
days <- sort(days, decreasing = TRUE)

cat(sprintf("  Processing %d day(s)\n", length(days)))

# ==================================================================
# STEP 4: Process each day
# ==================================================================
cat("\n[4] Processing daily data...\n")

for (day_start in days) {
  day_start_dt <- as.POSIXct(day_start, origin = "1970-01-01", tz = "UTC")
  day_end_dt <- day_start_dt + days(1)
  day_label <- format(day_start_dt, "%Y-%m-%d")

  cat(sprintf("\n  Day: %s\n", day_label))

  day_files <- file_data[file_data$day_start == day_start, ]
  cat(sprintf("    Files: %d\n", nrow(day_files)))

  # Download and combine polygons for this day
  all_features <- list()

  for (i in 1:min(nrow(day_files), 96)) { # Max 1 day * 96 = 96 files (15-min intervals)
    file_path <- day_files$path[i]
    timestamp <- day_files$timestamp[i]

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

  # Create GeoJSON for this day
  day_geojson <- list(
    type = "FeatureCollection",
    features = all_features,
    metadata = list(
      day = format(day_start_dt, "%Y-%m-%d"),
      file_count = length(all_features),
      generated = format(Sys.time(), "%Y-%m-%d %H:%M:%S")
    )
  )

  output_file <- file.path(output_dir, sprintf("day_%s.json", day_label))
  write_json(day_geojson, output_file, auto_unbox = TRUE, pretty = FALSE)

  file_size_mb <- file.size(output_file) / 1024 / 1024
  cat(sprintf("    ✓ Saved: %s (%.1f MB, %d features)\n",
              basename(output_file), file_size_mb, length(all_features)))
}

# ==================================================================
# STEP 5: Create day index
# ==================================================================
cat("\n[5] Creating day index...\n")

day_index <- data.frame(
  day = format(days, "%Y-%m-%d"),
  file = sprintf("day_%s.json", format(days, "%Y-%m-%d")),
  stringsAsFactors = FALSE
)

write_json(day_index, file.path(output_dir, "days.json"), pretty = TRUE)
cat(sprintf("  ✓ Index saved with %d day(s)\n", nrow(day_index)))

cat("\n✅ Processing complete!\n")
cat(sprintf("   Generated %d day file(s) in %s/\n", nrow(day_index), output_dir))
