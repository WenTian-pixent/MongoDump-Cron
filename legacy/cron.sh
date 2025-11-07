#!/bin/bash
folder="/mongodump-output"
fileName="$(date '+%Y-%m-%d-%H-%M-%S').log"
mkdir -p "$folder"
mongodump --uri="mongodb://host.docker.internal:27017" --db=playground --collection=providers --out=/var/backups >> "$folder/$fileName" 2>&1
