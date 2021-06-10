#!/usr/bin/env bash

set +e
set -o noglob


#
# Set Colors
#

bold="\e[1m"
dim="\e[2m"
underline="\e[4m"
blink="\e[5m"
reset="\e[0m"
red="\e[31m"
green="\e[32m"
blue="\e[34m"


#
# Common Output Styles
#

h1() {
  printf "\n${bold}${underline}%s${reset}\n" "$(echo "$@" | sed '/./,$!d')"
}
h2() {
  printf "\n${bold}%s${reset}\n" "$(echo "$@" | sed '/./,$!d')"
}
info() {
  printf "${dim}➜ %s${reset}\n" "$(echo "$@" | sed '/./,$!d')"
}
success() {
  printf "${green}✔ %s${reset}\n" "$(echo "$@" | sed '/./,$!d')"
}
error() {
  printf "${red}${bold}✖ %s${reset}\n" "$(echo "$@" | sed '/./,$!d')"
}
warnError() {
  printf "${red}✖ %s${reset}\n" "$(echo "$@" | sed '/./,$!d')"
}
warnNotice() {
  printf "${blue}✖ %s${reset}\n" "$(echo "$@" | sed '/./,$!d')"
}
note() {
  printf "\n${bold}${blue}Note:${reset} ${blue}%s${reset}\n" "$(echo "$@" | sed '/./,$!d')"
}

# Runs the specified command and logs it appropriately.
#   $1 = command
#   $2 = (optional) error message
#   $3 = (optional) success message
#   $4 = (optional) global variable to assign the output to
runCommand() {
  command="$1"
  info "$1"
  output="$(eval $command 2>&1)"
  ret_code=$?

  if [ $ret_code != 0 ]; then
    warnError "$output"
    if [ ! -z "$2" ]; then
      error "$2"
    fi
    exit $ret_code
  fi
  if [ ! -z "$3" ]; then
    success "$3"
  fi
  if [ ! -z "$4" ]; then
    eval "$4='$output'"
  fi
}

typeExists() {
  if [ $(type -P $1) ]; then
    return 0
  fi
  return 1
}

jsonValue() {
  key=$1
  num=$2
  awk -F"[,:}]" '{for(i=1;i<=NF;i++){if($i~/'$key'\042/){print $(i+1)}}}' | tr -d '"' | sed -n ${num}p
}

installAwsCli() {
  if ! typeExists "pip"; then
    h2 "Installing Python PIP"
    runCommand "sudo apt-get install -y python-pip"
    success "Installing PIP (`pip --version`) succeeded"
  fi

  h2 "Installing AWS CLI"
  runCommand "sudo pip install awscli"
}

installCoreUtils() {
    h2 "Installing CoreUtils"
    runCommand "HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTO_UPDATE=1 brew install coreutils"
    success "Installing CoreUtils succeeded"
}

vercomp() {
  if [[ $1 == $2 ]]
  then
    return 0
  fi
  local IFS=.
  local i ver1=($1) ver2=($2)

  # fill empty fields in ver1 with zeros
  for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
  do
    ver1[i]=0
  done

  for ((i=0; i<${#ver1[@]}; i++))
  do
    if [[ -z ${ver2[i]} ]]
    then
      # fill empty fields in ver2 with zeros
      ver2[i]=0
    fi
    if ((10#${ver1[i]} > 10#${ver2[i]}))
    then
      return 1
    fi
    if ((10#${ver1[i]} < 10#${ver2[i]}))
    then
      return 2
    fi
  done
  return 0
}

# Check variables

if [ -z "$AWS_CODE_DEPLOY_APPLICATION_NAME" ]; then
  error "Please set the \"\$AWS_CODE_DEPLOY_APPLICATION_NAME\" variable"
  exit 1
fi

if [ -z "$AWS_CODE_DEPLOY_DEPLOYMENT_GROUP_NAME" ]; then
  error "Please set the \"\$AWS_CODE_DEPLOY_DEPLOYMENT_GROUP_NAME\" variable"
  exit 1
fi

if [ -z "$AWS_CODE_DEPLOY_APP_SOURCE" ]; then
  error "Please set the \"\$AWS_CODE_DEPLOY_APP_SOURCE\" to a pre-packaged bundle or a directory to be deployed"
  exit 1
fi

if [ -z "$AWS_CODE_DEPLOY_S3_BUCKET" ]; then
  error "Please set the \"\$AWS_CODE_DEPLOY_S3_BUCKET\" variable"
  exit 1
fi

if [ -z "$AWS_CODE_DEPLOY_S3_FILENAME" ]; then
  error "Please set the \"\$AWS_CODE_DEPLOY_S3_FILENAME\" variable"
  exit 1
fi

if [[ -n "$AWS_CODE_DEPLOY_DEPLOYMENT_FILE_EXISTS_BEHAVIOR" && ! "$AWS_CODE_DEPLOY_DEPLOYMENT_FILE_EXISTS_BEHAVIOR" =~ ^(DISALLOW|OVERWRITE|RETAIN)$ ]]; then
  error "$AWS_CODE_DEPLOY_DEPLOYMENT_FILE_EXISTS_BEHAVIOR is not a valid option for the \"\$AWS_CODE_DEPLOY_DEPLOYMENT_FILE_EXISTS_BEHAVIOR\" variable"
  exit 1
fi


# ----- Install AWS Cli -----
# see documentation http://docs.aws.amazon.com/cli/latest/userguide/installing.html
# ---------------------------

# Check AWS is installed
h1 "Step 1: Checking Dependencies"


if ! typeExists "aws"; then
  installAwsCli
  success "Installing AWS CLI $(aws --version 2>&1) succeeded"
else
  # aws-cli 1.9.8 is required for proper SSE syntax
  AWS_FULL_VER=$(aws --version 2>&1)
  AWS_VER=$(echo $AWS_FULL_VER | sed -e 's/aws-cli\///' | sed -e 's/ Python.*//')
  vercomp $AWS_VER "1.9.8"
  if [[ $? == 2 ]]; then
    h2 "Installing updated AWS CLI version ($AWS_VER < 1.9.8)"
    installAwsCli
  fi

  success "Dependencies met $(aws --version 2>&1)"
fi  
if [[ "$OSTYPE" == "darwin"* ]]; then
   if ! typeExists "greadlink"; then
      installCoreUtils
      success "Installing CoreUtils  succeeded" 
    fi
fi




# ----- Configure -----
# see documentation
#    http://docs.aws.amazon.com/cli/latest/reference/configure/index.html
# ----------------------

h1 "Step 2: Configuring AWS"
if [ -z "$AWS_CODE_DEPLOY_KEY" ]; then
  # Ensure an access key has already been set
  if [ $(aws configure list | grep access_key | wc -l) -lt 1 ]; then
    error "No AWS_CODE_DEPLOY_KEY specified and AWS cli is not configured with an access key via env, config, or shared credentials"
    exit 1
  fi
  success "AWS Access Key already configured."
else
  $(aws configure set aws_access_key_id $AWS_CODE_DEPLOY_KEY 2>&1)
  success "Successfully configured AWS Access Key ID."
fi

if [ -z "$AWS_CODE_DEPLOY_SECRET" ]; then
  # Ensure an access key secret has already been set
  if [ $(aws configure list | grep secret_key | wc -l) -lt 1 ]; then
    error "No AWS_CODE_DEPLOY_SECRET specified and AWS cli is not configured with an access secret via env, config, or shared credentials"
    exit 1
  fi
  success "AWS Secret Access Key already configured."
else
  $(aws configure set aws_secret_access_key $AWS_CODE_DEPLOY_SECRET 2>&1)
  success "Successfully configured AWS Secret Access Key ID."
fi

if [ -z "$AWS_CODE_DEPLOY_REGION" ]; then
  # Ensure AWS region has already been set
  if [ $(aws configure list | grep region | wc -l) -lt 1 ]; then
    error "No AWS_CODE_DEPLOY_REGION specified and AWS cli is not configured with an existing default region via env, config, or shared credentials"
    exit 1
  fi
  success "AWS Region already configured."
else
  $(aws configure set default.region $AWS_CODE_DEPLOY_REGION 2>&1)
  success "Successfully configured AWS default region."
fi



# ----- Application -----
# see documentation
#    http://docs.aws.amazon.com/cli/latest/reference/deploy/get-application.html
#    http://docs.aws.amazon.com/cli/latest/reference/deploy/create-application.html
# ----------------------
# Application variables
APPLICATION_NAME="$AWS_CODE_DEPLOY_APPLICATION_NAME"
APPLICATION_VERSION=${AWS_CODE_DEPLOY_APPLICATION_VERSION:-${GIT_COMMIT:0:7}}

# Check application exists
h1 "Step 3: Checking Application"
APPLICATION_EXISTS="aws deploy get-application --application-name $APPLICATION_NAME"
info "$APPLICATION_EXISTS"
APPLICATION_EXISTS_OUTPUT=$($APPLICATION_EXISTS 2>&1)

if [ $? -ne 0 ]; then
  warnNotice "$APPLICATION_EXISTS_OUTPUT"
  h2 "Creating application \"$APPLICATION_NAME\""

  # Create application
  runCommand "aws deploy create-application --application-name $APPLICATION_NAME" \
             "Creating application \"$APPLICATION_NAME\" failed" \
             "Creating application \"$APPLICATION_NAME\" succeeded"
else
  success "Application \"$APPLICATION_NAME\" already exists"
fi



# ----- Deployment Config (optional) -----
# see documentation http://docs.aws.amazon.com/cli/latest/reference/deploy/create-deployment-config.html
# ----------------------
DEPLOYMENT_CONFIG_NAME=${AWS_CODE_DEPLOY_DEPLOYMENT_CONFIG_NAME:-CodeDeployDefault.OneAtATime}
MINIMUM_HEALTHY_HOSTS=${AWS_CODE_DEPLOY_MINIMUM_HEALTHY_HOSTS:-type=FLEET_PERCENT,value=75}

# Check deployment config exists
h1 "Step 4: Checking Deployment Config"
DEPLOYMENT_CONFIG_EXISTS="aws deploy get-deployment-config --deployment-config-name $DEPLOYMENT_CONFIG_NAME"
info "$DEPLOYMENT_CONFIG_EXISTS"
DEPLOYMENT_CONFIG_EXISTS_OUTPUT=$($DEPLOYMENT_CONFIG_EXISTS 2>&1)

if [ $? -ne 0 ]; then
  warnNotice "$DEPLOYMENT_CONFIG_EXISTS_OUTPUT"
  h2 "Creating deployment config \"$DEPLOYMENT_CONFIG_NAME\""

  # Create application
  runCommand "aws deploy create-deployment-config --deployment-config-name $DEPLOYMENT_CONFIG_NAME --minimum-healthy-hosts $MINIMUM_HEALTHY_HOSTS" \
             "Creating application \"$DEPLOYMENT_CONFIG_NAME\" failed" \
             "Creating application \"$DEPLOYMENT_CONFIG_NAME\" succeeded"
else
  success "Deployment config \"$DEPLOYMENT_CONFIG_NAME\" already exists"
fi



# ----- Deployment Group -----
# see documentation http://docs.aws.amazon.com/cli/latest/reference/deploy/create-deployment-config.html
# ----------------------
# Deployment group variables
DEPLOYMENT_GROUP=${AWS_CODE_DEPLOY_DEPLOYMENT_GROUP_NAME:-$DEPLOYTARGET_NAME}
AUTO_SCALING_GROUPS="$AWS_CODE_DEPLOY_AUTO_SCALING_GROUPS"
EC2_TAG_FILTERS="$AWS_CODE_DEPLOY_EC2_TAG_FILTERS"
SERVICE_ROLE_ARN="$AWS_CODE_DEPLOY_SERVICE_ROLE_ARN"

# Check deployment group exists
h1 "Step 5: Checking Deployment Group"
DEPLOYMENT_GROUP_EXISTS="aws deploy get-deployment-group --application-name $APPLICATION_NAME --deployment-group-name $DEPLOYMENT_GROUP"
info "$DEPLOYMENT_GROUP_EXISTS"
DEPLOYMENT_GROUP_EXISTS_OUTPUT=$($DEPLOYMENT_GROUP_EXISTS 2>&1)

if [ $? -ne 0 ]; then
  warnNotice "$DEPLOYMENT_GROUP_EXISTS_OUTPUT"
  h2 "Creating deployment group \"$DEPLOYMENT_GROUP\" for application \"$APPLICATION_NAME\""

  # Create deployment group
  DEPLOYMENT_GROUP_CREATE="aws deploy create-deployment-group --application-name $APPLICATION_NAME --deployment-group-name $DEPLOYMENT_GROUP --deployment-config-name $DEPLOYMENT_CONFIG_NAME"

  if [ -n "$SERVICE_ROLE_ARN" ]; then
    DEPLOYMENT_GROUP_CREATE="$DEPLOYMENT_GROUP_CREATE --service-role-arn $SERVICE_ROLE_ARN"
  fi
  if [ -n "$AUTO_SCALING_GROUPS" ]; then
    DEPLOYMENT_GROUP_CREATE="$DEPLOYMENT_GROUP_CREATE --auto-scaling-groups $AUTO_SCALING_GROUPS"
  fi
  if [ -n "$EC2_TAG_FILTERS" ]; then
    DEPLOYMENT_GROUP_CREATE="$DEPLOYMENT_GROUP_CREATE --ec2-tag-filters $EC2_TAG_FILTERS"
  fi

  runCommand "$DEPLOYMENT_GROUP_CREATE" \
             "Creating deployment group \"$DEPLOYMENT_GROUP\" for application \"$APPLICATION_NAME\" failed" \
             "Creating deployment group \"$DEPLOYMENT_GROUP\" for application \"$APPLICATION_NAME\" succeeded"
else
  success "Deployment group \"$DEPLOYMENT_GROUP\" already exists for application \"$APPLICATION_NAME\""
fi


# ----- Application Source -----
h1 "Step 6: Checking Application Source"
AWS_CODE_DEPLOY_APP_BUNDLE_TYPE=${AWS_CODE_DEPLOY_APP_BUNDLE_TYPE:-zip}
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    APP_SOURCE=$(readlink -f "${AWS_CODE_DEPLOY_APP_SOURCE:-.}")    
elif [[ "$OSTYPE" == "darwin"* ]]; then
    APP_SOURCE=$(greadlink -f "${AWS_CODE_DEPLOY_APP_SOURCE:-.}")
else
   APP_SOURCE=$(realpath -f "${AWS_CODE_DEPLOY_APP_SOURCE:-.}")
fi

if [ ! -d "$APP_SOURCE" -a ! -e "$APP_SOURCE" ]; then
  # Note: Use original variable for output as the readlink can potentially evaluate to ""
  error "The specified application source \"${AWS_CODE_DEPLOY_APP_SOURCE}\" does not exist."
  exit 1
fi
if [ -d "$APP_SOURCE" ]; then
  if [ ! -e "$APP_SOURCE/appspec.yml" ]; then
    error "The specified source directory \"${APP_SOURCE}\" does not contain an \"appspec.yml\" in the application root."
    exit 1
  fi
  if [ $AWS_CODE_DEPLOY_APP_BUNDLE_TYPE == "tgz" ]; then
    if ! typeExists "tar" -o ! typeExists "gzip"; then
      note "Installing tar and gzip binaries ..."
      sudo apt-get install -y tar gzip
      note "Tar and GZip binaries installed."
    fi
    BUNDLE_EXTENSION="tar.gz"
  else  ## defaults to zip
    if ! typeExists "zip"; then
      note "Installing zip binaries ..."
      sudo apt-get install -y zip
      note "Zip binaries installed."
    fi
    BUNDLE_EXTENSION="zip"
  fi
  DEPLOYMENT_COMPRESS_ORIG_DIR_SIZE=$(du -hs $APP_SOURCE | awk '{ print $1}')
  APP_LOCAL_FILE="${AWS_CODE_DEPLOY_S3_FILENAME%.*}.${BUNDLE_EXTENSION}"
  APP_LOCAL_TEMP_FILE="/tmp/$APP_LOCAL_FILE"

  if [ $AWS_CODE_DEPLOY_APP_BUNDLE_TYPE == "tgz" ]; then
    runCommand "tar -zcvf \"${APP_LOCAL_TEMP_FILE}\" -C \"$APP_SOURCE\" ." \
               "Unable to compress \"$APP_SOURCE\""
    BUNDLE_TYPE="tgz"
  else  ## defaults to zip
    runCommand "cd \"$APP_SOURCE\" && zip -rq \"${APP_LOCAL_TEMP_FILE}\" ." \
               "Unable to compress \"$APP_SOURCE\""
    BUNDLE_TYPE="zip"
  fi
  DEPLOYMENT_COMPRESS_FILESIZE=$(ls -lah "${APP_LOCAL_TEMP_FILE}" | awk '{ print $5}')
  success "Successfully compressed \"$APP_SOURCE\" ($DEPLOYMENT_COMPRESS_ORIG_DIR_SIZE) into \"$APP_LOCAL_FILE\" ($DEPLOYMENT_COMPRESS_FILESIZE)"
else
  APP_SOURCE_BASENAME=$(basename "$APP_SOURCE")
  APP_SOURCE_FILESIZE=$(ls -lah "${APP_SOURCE}" | awk '{ print $5}')
  EXTENSION="${APP_SOURCE#*.}"

  if [ $EXTENSION == "tar" ]; then
    BUNDLE_TYPE="tar"
  elif [ $EXTENSION == "tar.gz" ]; then
    BUNDLE_TYPE="tgz"
  elif [ $EXTENSION == "zip" ]; then
    BUNDLE_TYPE="zip"
  else
    error "Unsupported bundle type for application source file: ${APP_SOURCE_BASENAME} - Must be tar, zip or tgz"
    exit 1
  fi

  APP_LOCAL_FILE=$APP_SOURCE_BASENAME
  APP_LOCAL_TEMP_FILE=$APP_SOURCE

  success "Valid source file: $APP_SOURCE_BASENAME ($BUNDLE_TYPE) ($APP_SOURCE_FILESIZE)"
fi



# ----- Push Bundle to S3 -----
# see documentation  http://docs.aws.amazon.com/cli/latest/reference/s3/cp.html
# ----------------------
h1 "Step 7: Copying Bundle to S3"
S3_CP="aws s3 cp"
S3_BUCKET=${AWS_CODE_DEPLOY_S3_BUCKET}
S3_FULL_BUCKET=${S3_BUCKET}

# Strip off any "/" from front and end, but allow inside
S3_KEY_PREFIX=$(echo "${AWS_CODE_DEPLOY_S3_KEY_PREFIX}" | sed 's/^\/\?\(.*[^\/]\)\/\?$/\1/')

if [ ! -z "${S3_KEY_PREFIX}" ]; then
    S3_FULL_BUCKET="${S3_FULL_BUCKET}/${S3_KEY_PREFIX}"
fi

if [ "${AWS_CODE_DEPLOY_S3_SSE}" == "true" ]; then
  S3_CP="${S3_CP} --sse AES256"
fi

runCommand "${S3_CP} \"${APP_LOCAL_TEMP_FILE}\" \"s3://${S3_FULL_BUCKET}/${AWS_CODE_DEPLOY_S3_FILENAME}\"" \
           "Unable to copy bundle \"${APP_LOCAL_TEMP_FILE}\" to S3" \
           "Successfully copied bundle \"${APP_LOCAL_TEMP_FILE}\" to s3://${S3_FULL_BUCKET}/${AWS_CODE_DEPLOY_S3_FILENAME}"



# ----- Limit Deploy Revisions per Bucket/Key  -----
# see documentation  http://docs.aws.amazon.com/cli/latest/reference/s3/cp.html
# ----------------------
h1 "Step 8: Limiting Deploy Revisions per Bucket/Key"
S3_DEPLOY_LIMIT=${AWS_CODE_DEPLOY_S3_LIMIT_BUCKET_FILES:-0}
if [ $S3_DEPLOY_LIMIT -lt 1 ]; then
  success "Skipping deploy revision max files per bucket/key."
else
  h2 "Checking bucket/key to limit total revisions at ${S3_DEPLOY_LIMIT} files ..."
  S3_LS_OUTPUT=""
  runCommand "aws s3 ls \"s3://$S3_FULL_BUCKET/\"" \
             "Unable to list directory contents \"$S3_BUCKET/\"" \
             "" \
             S3_LS_OUTPUT

  # Sort the output by date first
  S3_LS_OUTPUT=$(echo "$S3_LS_OUTPUT" | sort)

  # Filter out S3 prefixes (These do not count, especially useful in root bucket location)
  S3_FILES=()
  IFS=$'\n';
  for line in $S3_LS_OUTPUT; do
    if [[ ! $line =~ ^[[:space:]]+PRE[[:space:]].*$ ]]; then
      S3_FILES+=("$line")
    fi
  done

  S3_TOTAL_FILES=${#S3_FILES[@]}
  S3_NUMBER_FILES_TO_CLEAN=$(($S3_TOTAL_FILES-$S3_DEPLOY_LIMIT))
  if [ $S3_NUMBER_FILES_TO_CLEAN -gt 0 ]; then
    h2 "Removing oldest $S3_NUMBER_FILES_TO_CLEAN file(s) ..."
    for line in "${S3_FILES[@]}"; do
      if [ $S3_NUMBER_FILES_TO_CLEAN -le 0 ]; then
        success "Successfuly removed $(($S3_TOTAL_FILES-$S3_DEPLOY_LIMIT)) file(s)"
        break
      fi
      #FILE_LINE=$(expr "$line" : '^.*[0-9]\{2\}\:[0-9]\{2\}\:[0-9]\{2\}[ ]\+[0-9]\+[ ]\+\(.*\)$')
      FILE_LINE=`(echo $line | awk '{$1=$2=$3=""; print $0}' | sed 's/^[ \t]*//')`
      runCommand "aws s3 rm \"s3://$S3_FULL_BUCKET/$FILE_LINE\""
      ((S3_NUMBER_FILES_TO_CLEAN--))
    done
  else
    success "File count under limit. No need to remove old files. (Total Files = $S3_TOTAL_FILES, Limit = $S3_DEPLOY_LIMIT)"
  fi
fi



# ----- Register Revision -----
# see documentation http://docs.aws.amazon.com/cli/latest/reference/deploy/register-application-revision.html
# ----------------------
h1 "Step 9: Registering Revision"

REGISTER_APP_CMD="aws deploy register-application-revision --application-name \"$APPLICATION_NAME\""

if [ -n "$S3_KEY_PREFIX" ]; then
  S3_LOCATION="bucket=${S3_BUCKET},bundleType=${BUNDLE_TYPE},key=${S3_KEY_PREFIX}/${AWS_CODE_DEPLOY_S3_FILENAME}"
else
  S3_LOCATION="bucket=${S3_BUCKET},bundleType=${BUNDLE_TYPE},key=${AWS_CODE_DEPLOY_S3_FILENAME}"
fi

REGISTER_APP_CMD="${REGISTER_APP_CMD} --s3-location ${S3_LOCATION}"

if [ ! -z "${AWS_CODE_DEPLOY_REVISION_DESCRIPTION}" ]; then
    REGISTER_APP_CMD="${REGISTER_APP_CMD} --description \"${AWS_CODE_DEPLOY_REVISION_DESCRIPTION}\""
fi

runCommand "${REGISTER_APP_CMD}" \
           "Registering revision failed" \
           "Registering revision succeeded"



# ----- Create Deployment -----
# see documentation http://docs.aws.amazon.com/cli/latest/reference/deploy/create-deployment.html
# ----------------------
DEPLOYMENT_DESCRIPTION="$AWS_CODE_DEPLOY_DEPLOYMENT_DESCRIPTION"
h1 "Step 10: Creating Deployment"
DEPLOYMENT_CMD="aws deploy create-deployment --output json --application-name $APPLICATION_NAME --deployment-config-name $DEPLOYMENT_CONFIG_NAME --deployment-group-name $DEPLOYMENT_GROUP --s3-location $S3_LOCATION"

if [ -n "$DEPLOYMENT_DESCRIPTION" ]; then
  DEPLOYMENT_CMD="$DEPLOYMENT_CMD --description \"$DEPLOYMENT_DESCRIPTION\""
fi


DEPLOYMENT_OUTPUT=""
runCommand "$DEPLOYMENT_CMD" \
           "Deployment of application \"$APPLICATION_NAME\" on deployment group \"$DEPLOYMENT_GROUP\" failed" \
           "" \
           DEPLOYMENT_OUTPUT

DEPLOYMENT_ID=$(echo $DEPLOYMENT_OUTPUT | jsonValue 'deploymentId' | tr -d ' ')
success "Successfully created deployment: \"$DEPLOYMENT_ID\""
note "You can follow your deployment at: https://console.aws.amazon.com/codedeploy/home#/deployments/$DEPLOYMENT_ID"



# ----- Monitor Deployment -----
# see documentation http://docs.aws.amazon.com/cli/latest/reference/deploy/create-deployment.html
# ----------------------
DEPLOYMENT_OVERVIEW=${AWS_CODE_DEPLOY_DEPLOYMENT_OVERVIEW:-true}
if [ "true" == "$DEPLOYMENT_OVERVIEW" ]; then
  h1 "Deployment Overview"

  DEPLOYMENT_GET="aws deploy get-deployment --output json --deployment-id \"$DEPLOYMENT_ID\""
  h2 "Monitoring deployment \"$DEPLOYMENT_ID\" for \"$APPLICATION_NAME\" on deployment group $DEPLOYMENT_GROUP ..."
  info "$DEPLOYMENT_GET"

  # If the environment supports live reloading use carriage returns for a single line.
  if [ "true" == "${AWS_CODE_DEPLOY_OUTPUT_STATUS_LIVE}" ]; then
    status_opts="\r${bold}"
    status_opts_live="\r${bold}${blink}"
    printf "\n"
  else
    status_opts="\n${bold}"
    status_opts_live="\n${bold}"
  fi

  while :
    do
      DEPLOYMENT_GET_OUTPUT="$(eval $DEPLOYMENT_GET 2>&1)"
      if [ $? != 0 ]; then
        warnError "$DEPLOYMENT_GET_OUTPUT"
        error "Deployment of application \"$APPLICATION_NAME\" on deployment group \"$DEPLOYMENT_GROUP\" failed"
        exit 1
      fi

      # Deployment Overview
      IN_PROGRESS=$(echo "$DEPLOYMENT_GET_OUTPUT" | jsonValue "InProgress" | tr -d "\r\n ")
      PENDING=$(echo "$DEPLOYMENT_GET_OUTPUT" | jsonValue "Pending" | tr -d "\r\n ")
      SKIPPED=$(echo "$DEPLOYMENT_GET_OUTPUT" | jsonValue "Skipped" | tr -d "\r\n ")
      SUCCEEDED=$(echo "$DEPLOYMENT_GET_OUTPUT" | jsonValue "Succeeded" | tr -d "\r\n ")
      FAILED=$(echo "$DEPLOYMENT_GET_OUTPUT" | jsonValue "Failed" | tr -d "\r\n ")

      if [ "$IN_PROGRESS" == "" ]; then IN_PROGRESS="-"; fi
      if [ "$PENDING" == "" ]; then PENDING="-"; fi
      if [ "$SKIPPED" == "" ]; then SKIPPED="-"; fi
      if [ "$SUCCEEDED" == "" ]; then SUCCEEDED="-"; fi
      if [ "$FAILED" == "" ]; then FAILED="-"; fi

      # Deployment Status
      STATUS=$(echo "$DEPLOYMENT_GET_OUTPUT" | jsonValue "status" | tr -d "\r\n" | tr -d " ")
      ERROR_MESSAGE=$(echo "$DEPLOYMENT_GET_OUTPUT" | jsonValue "message")

      printf "${status_opts_live}Status${reset}  | In Progress: $IN_PROGRESS  | Pending: $PENDING  | Skipped: $SKIPPED  | Succeeded: $SUCCEEDED  | Failed: $FAILED  | "

      # Print Failed Details
      if [ "$STATUS" == "Failed" ]; then
        printf "${status_opts}Status${reset}  | In Progress: $IN_PROGRESS  | Pending: $PENDING  | Skipped: $SKIPPED  | Succeeded: $SUCCEEDED  | Failed: $FAILED  | \n\n"       
        error "Deployment failed: $ERROR_MESSAGE"

        # Retrieve failed instances. Use text output here to easier retrieve array. Output format:
        # INSTANCESLIST   i-1497a9e2
        # INSTANCESLIST   i-23a541eb
        LIST_INSTANCES_OUTPUT=""
        h2 "Retrieving failed instance details ..."
        runCommand "aws deploy list-deployment-instances --deployment-id $DEPLOYMENT_ID --instance-status-filter Failed --output text" \
                   "" \
                   "" \
                   LIST_INSTANCES_OUTPUT

        INSTANCE_IDS=($(echo "$LIST_INSTANCES_OUTPUT" | sed -r 's/INSTANCESLIST\s+//g'))
        INSTANCE_IDS_JOINED=$(printf ", %s" "${INSTANCE_IDS[@]}")
        success "Found ${#INSTANCE_IDS[@]} failed instance(s) [ ${INSTANCE_IDS_JOINED:2} ]"

        # Enumerate over each failed instance
        for i in "${!INSTANCE_IDS[@]}"; do
          FAILED_INSTANCE_OUTPUT=$(aws deploy get-deployment-instance --deployment-id $DEPLOYMENT_ID --instance-id ${INSTANCE_IDS[$i]} --output text)
          printf "\n${bold}Instance: ${INSTANCE_IDS[$i]}${reset}\n"

          echo "$FAILED_INSTANCE_OUTPUT" | while read -r line; do

            case "$(echo $line | awk '{ print $1; }')" in

              INSTANCESUMMARY)

                printf "    Instance ID:  %s\n" "$(echo $line | awk '{ print $3; }')"
                printf "         Status:  %s\n" "$(echo $line | awk '{ print $5; }')"
                printf "Last Updated At:  %s\n\n" "$(date -d @$(echo $line | awk '{ print $4; }'))"
                ;;

              # The text version should have either 3 or 5 arguments
              # LIFECYCLEEVENTS            ValidateService         Skipped
              # LIFECYCLEEVENTS    1434231363.6    BeforeInstall   1434231363.49   Failed
              # LIFECYCLEEVENTS    1434231361.79   DownloadBundle  1434231361.34   Succeeded
              LIFECYCLEEVENTS)
                # For now, lets just strip off start/stop times. Also convert tabs to spaces
                lineModified=$(echo "$line" | sed -r 's/[0-9]+\.[0-9]+//g' | sed 's/\t/    /g')

                # Bugfix: Ubuntu 12.04 has some weird issues with spacing as seen on CircleCI. We fix this
                # by just condensing down to single spaces and ensuring the proper separator.
                IFS=$' '
                ARGS=($(echo "$lineModified" | sed -r 's/\s+/ /g'))

                if [ ${#ARGS[@]} == 3 ]; then
                  case "${ARGS[2]}" in
                    Succeeded)
                      printf "${bold}${green}✔ [%s]${reset}\t%s\n" "${ARGS[2]}" "${ARGS[1]}"
                      ;;

                    Skipped)
                      printf "${bold}  [%s]${reset}\t%s\n" "${ARGS[2]}" "${ARGS[1]}"
                      ;;

                    Failed)
                      printf "${bold}${red}✖ [%s]${reset}\t%s\n" "${ARGS[2]}" "${ARGS[1]}"
                      ;;
                  esac

                else
                  echo "[UNKNOWN] (${#ARGS[@]}) $lineModified"
                fi
                ;;

              DIAGNOSTICS)
                # Skip diagnostics if we have "DIAGNOSTICS      Success         Succeeded"
                if [ "$(echo $line | awk '{ print $2; }')" == "Success" ] && [ "$(echo $line | awk '{ print $3; }')" == "Succeeded" ]; then
                  continue
                fi

                # Just pipe off the DIAGNOSTICS
                printf "${red}%s${reset}\n" "$(echo $line | sed -r 's/^DIAGNOSTICS\s*//g')"
                ;;

              *)
                printf "${red}${line}${reset}\n"
                ;;

            esac

          done # end: while

        done # ~ end: instance

        printf "\n\n"
        exit 1
      fi

      # Deployment succeeded
      if [ "$STATUS" == "Succeeded" ]; then
         printf "${status_opts}Status${reset}  | In Progress: $IN_PROGRESS  | Pending: $PENDING  | Skipped: $SKIPPED  | Succeeded: $SUCCEEDED  | Failed: $FAILED  | \n\n"
         success "Deployment of application \"$APPLICATION_NAME\" on deployment group \"$DEPLOYMENT_GROUP\" succeeded"
         break
      fi

      sleep 2
   done
fi
