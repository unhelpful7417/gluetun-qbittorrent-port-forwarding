FROM alpine:latest

# Set working directory
WORKDIR /app

# Install dependencies
RUN apk add --no-cache curl jq tzdata

# Copy in the script
COPY qbit-api-set-port.sh .

# Ensure script is executable. Don't need to do this since the script is already executable, but just to be safe
RUN chmod +x qbit-api-set-port.sh

# Make sure the script always runs when the container starts and logs are sent to STDOUT
ENTRYPOINT [ "/app/qbit-api-set-port.sh" ]
