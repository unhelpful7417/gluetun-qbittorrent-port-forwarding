#!/bin/ash
set -e # Any errors break the script and stop the container. The restart policy will restart the container to try again

# * PURPOSE: Log messages to STDOUT
# * ARGUMENTS: Two strings - first is content of log message, second is verbal representation of logging level
log() {
  local message=$1 # Contents of log message
  local level=$2 # Logging level of the log message
  local msgLevelIndex=$(getLogLevelIndex "$level") # Get the numerical form of the logging level for this message

  # If the globally defined logging level is configured to view this message, then echo to STDOUT
  if [ "$msgLevelIndex" -ge "$logLevelIndex" ]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [$level] $message"
  fi
}
# * PURPOSE: Define logging levels in both verbal and numerical representations and also get the log index from the word (e.g., ERROR has a log level of 2)
# * ARGUMENTS: One string - either DEBUG, INFO, or ERROR
getLogLevelIndex() {
  case $1 in
    "DEBUG") echo 0 ;;
    "INFO") echo 1 ;;
    "ERROR") echo 2 ;;
    *) echo "Log level $1 not defined" && exit 1 ;; # I'm pretty sure an invalid log level gets picked up in the data validation
  esac                                              # section later on but it feels wrong to not have any error handling here
}

# * PURPOSE: Function to check if value of a variable is defined
# * ARGUMENTS: One variable
isNotEmpty() {
  local name="${1}" # Get the name of the variable
  local value=""          # Get the value of the variable
  eval "value=\"\$${1}\"" # using some certified Jank^TM

  # Throw error if variable is empty
  if [ -z $value ]; then
    log "${name} is undefined - make sure you're setting your environment variables properly" ERROR
    exit 1
  fi
}
# * PURPOSE: Function to check if value of a variable is a number
# * ARGUMENTS: One string - name of variable (i.e. without the $)
isNumber() {
  local name="${1}" # Get the name of the variable
  local value=""          # Get the value of the variable
  eval "value=\"\$${1}\"" # using some certified Jank^TM

  # Make sure the value of the input variable is a number
  if ! echo "$value" | grep -qE '^[0-9]+$'; then
    log "${name} is not a number, but it should be" ERROR
    exit 1
  fi
}

# Declare some variables
export qbCookiejar=/tmp/cookies.txt # Store API session ID here for later. Write to /tmp so the container can run as any user and still have write permissions - although I'm not a huge fan of storing session cookies in a public folder
export qbResponse=/tmp/response.json # Store qBit config here for parsing later
export sleepTime=${sleepTime:-1800} # Time to wait between running the check. Defaults to 30m
export logLevel=${logLevel:-INFO} # Set the default logging level to INFO
export qbHostname=${qbHostname:-http://localhost:8080} # Set the default qBittorrent URL - assuming most users will attach this container to Gluetun
export gtHostname=${gtHostname:-http://localhost:8000} # Set the default Gluetun URL - assuming most users will attach this container to Gluetun

# Do some data validation on our variables. We pass them into the validation functions as strings - function parses them as variables
isNotEmpty qbUsername
isNotEmpty qbPassword
isNumber sleepTime
# Manual data validation for the logLevel variable. Must be either DEBUG, INFO, or ERROR
if [ "${logLevel}" != "DEBUG" ] && [ "${logLevel}" != "INFO" ] && [ "${logLevel}" != "ERROR" ]; then
  message="The logging level was set to an invalid value: \"${logLevel}\". Valid values are DEBUG, INFO, and ERROR. Default value is INFO"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] [ERROR] $message" # Rawdog the log output since an invalid log level breaks the logging function
  exit 1
fi
export logLevelIndex=$(getLogLevelIndex "$logLevel") # Get logging level in numerical form now that we know it's valid

# Wait for Gluetun to get a forwarded port
log "Data validation checks all passed. Waiting 30s for Gluetun to get a port forwarded" DEBUG
sleep 30

# * PURPOSE: An endless loop that ensures that the Gluetun forwarded port exists and qBit is configured to use it
# I think the forwarded port should stay the same as long as Gluetun is running, but I think some providers will time out and Gluetun may request a new forwarded port. 
# Might revert this script to just perform the check once and exit, but I like ensuring the state is always what we want it to be and not assuming nothing has changed
while true; do
  # Try to get the forwarded port from the Gluetun API
  log "Attempting to authenticate to ${gtHostname}" DEBUG
  gtResponse=$(curl -sL ${gtHostname}/v1/openvpn/portforwarded)
  gtForwardedPort=$(echo ${gtResponse} | jq -r '.port') # Parse the port from the API response
  # Validate the reponse from the Gluetun API
  if [ ${gtForwardedPort} -eq 0 ]; then
    # Gluetun responds with "0" if it hasn't gotten a port yet. If we get that, exit with error
    log "Gluetun has not gotten a port yet. Exiting to retry" ERROR
    exit 1
  elif echo "${gtForwardedPort}" | grep -qE '^[0-9]{1,5}$'; then
    # If the port is not a zero but is a number with 1-5 digits, then it's probably a valid port. This is our "success" condition
    log "Gluetun has a forwarded port ${gtForwardedPort}" DEBUG
  else
    # If the port is not a number with 1-5 digits, then it's not a valid port to forward so we log the output as an error
    log "Response from Gluetun API is invalid. Value was: ${gtResponse}" ERROR
    exit 1
  fi

  # Log in to qBit API
  log "Attempting to authenticate to ${qbHostname}" DEBUG
  curlOutput=$(curl -sL --header "Referer: ${qbHostname}" --data "username=${qbUsername}&password=${qbPassword}" -c ${qbCookiejar} ${qbHostname}/api/v2/auth/login)
  if [ "${curlOutput}" = "Ok." ]; then
    log "Successfully authenticated to the qBit API" DEBUG
  else
    log "API returned the following message upon authentication attempt: ${curlOutput}" ERROR
    exit 1
  fi

  # * PURPOSE: Get qBit config and save it to text file
  # I wanted to use a variable but if you have any banned IP's in your qBit config, they're separated with newline characters which may
  # come back as literal newlines and not escaped. Saving it to a file makes those newlines always escaped which makes parsing easier
  curl -sSL -b ${qbCookiejar} ${qbHostname}/api/v2/app/preferences > ${qbResponse}

  # Parse listen port from config
  # TODO: Error handling for this in case for some reason, the API messed up in between when we authenticated earlier and right now
  qbListenPort=$(jq -r '.listen_port' ${qbResponse})
  log "qBit is currently listening on port ${qbListenPort}" DEBUG

  # If the forwarded port from Gluetun != port that qBit is configured to listen on, then set the qBit listening port to what we get from Gluetun
  if [ ${gtForwardedPort} -ne ${qbListenPort} ]; then
    curl -sSL -b ${qbCookiejar} ${qbHostname}/api/v2/app/setPreferences --data 'json={"listen_port":"'${gtForwardedPort}'"}'
    log "Updated qBit listening port from ${qbListenPort} to ${gtForwardedPort}" INFO
  else
    log "qBit listening port is already configured properly. Currently listening on ${gtForwardedPort}" INFO
  fi

  # Wait a while before checking again
  sleep ${sleepTime}
done