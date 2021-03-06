#!/bin/bash

#
# alice-install.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Installs all the ALICE software on Ubuntu/Mac hopefully with the least
# possible human intervention.
#

#
# Variables
#

export SWALLOW_LOG="/tmp/alice-autobuild-$USER"
export ERR="$SWALLOW_LOG.err"
export OUT="$SWALLOW_LOG.out"
export ENVSCRIPT=""
export NCORES=0
export BUILD_MODE='' # clang, gcc, custom-gcc
export SUPPORTED_BUILD_MODES=''
export CUSTOM_GCC_PATH='/opt/gcc'
export BUILDOPT_LDFLAGS=''
export BUILDOPT_CPATH=''
export ALIEN_INSTALL_TYPE=''
export DOWNLOAD_MODE=''

#
# Functions
#

# Sources environment variables
function SourceEnvVars() {
  local R
  source "$ENVSCRIPT" -n
  R=$?
  [ $NCORES -gt 0 ] && MJ=$NCORES
  return $R
}

# Returns date in current timezone in a compact format
function DateTime() {
  date +%Y%m%d-%H%M%S
}

# Prints the time given in seconds in hours, minutes, seconds
function NiceTime() {
  local SS HH MM STR
  SS="$1"

  let "HH=SS / 3600"
  let "SS=SS % 3600"
  [ $HH -gt 0 ] && STR=" ${HH}h"

  let "MM=SS / 60"
  let "SS=SS % 60"
  [ $MM -gt 0 ] && STR="${STR} ${MM}m"

  [ $SS -gt 0 ] && STR="${STR} ${SS}s"
  [ "$STR" == "" ] && STR="0s"

  echo $STR

  #printf "%02dh %02dm %02ds" $HH $MM $SS
}

# Prints the command name when it is started.
#  - $1: command description
function SwallowStart() {
  local MSG OP

  OP="$1"
  shift

  MSG='*** ['"$(DateTime)"'] BEGIN OP='"$OP"' CWD='"$PWD"' CMD='"$@"' ***'
  echo -e "$MSG" >> "$OUT"
  echo -e "$MSG" >> "$ERR"

  echo -en "[....] $OP..."

}

# Prints command's progress with percentage and time.
#  - $1: command description
#  - $2: current percentage
#  - $3: start timestamp (seconds)
function SwallowStep() {
  local TS_START OP MSG PCT PCT_FMT

  OP="$1"
  PCT=$2
  TS_START=${3}

  let TS_DELTA=$(date +%s)-TS_START

  # Prints progress
  echo -ne '\r                                                  \r'
  PCT_FMT=$( printf "%3d%%" $PCT )
  echo -ne "[\033[34m$PCT_FMT\033[m] $OP \033[36m$(NiceTime $TS_DELTA)\033[m"

  return $RET

}

# Prints the command with its exit status (OK or FAILED) and time taken.
#  - $1: command description
#  - $2: the exit code of command
#  - $3: start timestamp (seconds) (optional)
#  - $4: end timestamp (seconds) (optional)
#  - $@: the command (from $5 on)
function SwallowEnd() {

  local TS_END TS_START OP MSG RET

  OP="$1"
  FATAL=$2
  RET=$3
  TS_START=${4-0}  # defaults to 0
  TS_END=${5-0}

  # After this line, $@ will contain the command
  shift 5

  let TS_DELTA=TS_END-TS_START

  # Prints success (green OK) or fail (red FAIL). In case FATAL=0
  # prints a warning (yellow SKIP) instead of an error
  echo -ne '\r'
  if [ $RET == 0 ]; then
    echo -ne '[ \033[32mOK\033[m ]'
  elif [ $FATAL == 0 ]; then
    echo -ne '[\033[33mSKIP\033[m]'
  else
    echo -ne '[\033[31mFAIL\033[m]'
  fi
  echo -ne " ${OP}"

  # Prints time only if greater than 1 second
  if [ $TS_DELTA -gt 1 ]; then
    echo -e " \033[36m$(NiceTime $TS_DELTA)\033[m"
  else
    echo "   "
  fi

  # On the log files (out, err)
  MSG='*** ['"$(DateTime)"'] END OP='"$OP"' CWD='"$PWD"' ERR='"$RET"' CMD='"$@"' ***'
  echo -e "$MSG" >> "$OUT"
  echo -e "$MSG" >> "$ERR"

  return $RET
}

# Sends everything to a logfile
function Swallow() {

  local MSG RET TSSTART TSEND DELTAT FATAL OP

  # Abort on errors?
  if [ "$1" == "-f" ]; then
    FATAL=1
    shift
  else
    FATAL=0
  fi

  OP="$1"
  shift

  SwallowStart "$OP" "$@"
  TSSTART=$(date +%s)

  "$@" >> "$OUT" 2>> "$ERR"
  RET=$?

  TSEND=$(date +%s)
  SwallowEnd "$OP" $FATAL $RET $TSSTART $TSEND "$@"

  if [ $RET != 0 ] && [ $FATAL == 1 ]; then
    LastLogLines -e "$OP"
    exit 1
  fi

  return $RET
}

# Interactively asks to accept SVN certificates
function InteractiveAcceptSvn() {
  local SVN_SERVERS='root.cern.ch svn.cern.ch'
  Banner 'Please accept those SVN certificates permanently if requested'
  for S in $SVN_SERVERS ; do
    svn info https://$S  # always returns 1...
  done
  return 0
}

# Prints the last lines of both log files
function LastLogLines() {
  local LASTLINES=20
  local ISERROR=0

  if [ "$1" == "-e" ]; then
    echo ""
    echo -e "\033[41m\033[1;37mOperation \"$2\" ended with errors\033[m"
  fi

  echo ""
  echo -e "\033[33m=== Last $LASTLINES lines of stdout -- $SWALLOW_LOG.out ===\033[m"
  tail -n$LASTLINES "$SWALLOW_LOG".out
  echo ""
  echo -e "\033[33m=== Last $LASTLINES lines of stderr -- $SWALLOW_LOG.err ===\033[m"
  tail -n$LASTLINES "$SWALLOW_LOG".err
  echo ""

  [ "$1" == "-e" ] && ShowBugReportInfo
}

# Echoes a colored banner
function Banner() {
  echo ""
  echo -e '\033[33m'"$1"'\033[m'
}

# Tries different SVN servers before giving up on error. Arguments:
#  - $1: pipe-separated list of servers with protocol, i.e.:
#        "https://root.cern.ch|http://root.cern.ch|svn://root.cern.ch"
#  - $@: svn command: @SERVER@ will be substituted with proto://server
function MultiSvn() {
  local SvnServers OldIFS Srv Arg NewArg SvnCmd
  SvnServers="$1"
  shift
  OldIFS="$IFS"
  IFS='|'
  for Srv in $SvnServers ; do
    IFS="$OldIFS"

    # Substitute @SERVER@ in command
    SvnCmd=( svn )
    for Arg in $@ ; do
      NewArg=`echo "$Arg" | sed -e "s#@SERVER@#$Srv#g"`
      SvnCmd[${#SvnCmd[@]}]="$NewArg"
    done

    echo "--> Trying SVN command: ${SvnCmd[@]}"
    ${SvnCmd[@]} && return 0  # IFS is the right one
    echo "--> SVN command failed: ${SvnCmd[@]}"

    IFS='|'
  done
  IFS="$OldIFS"
  return 1
}

# Prepares information for bug report
function PrepareBugReport() {

  # Source environment variables (non-fatal)
  SourceEnvVars >> $OUT 2>&1

  # Some environment variables
  (
    echo "PATH=$PATH"
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    echo "DYLD_LIBRARY_PATH=$DYLD_LIBRARY_PATH"
    echo "uname -a: `uname -a`"
    echo "which gcc: `which gcc 2>/dev/null`"
    echo "which g++: `which g++ 2>/dev/null`"
    echo "which clang: `which clang 2>/dev/null`"
    echo "which clang++: `which clang++ 2>/dev/null`"
    echo "which gfortran: `which gfortran 2>/dev/null`"
    echo "which ld: `which ld 2>/dev/null`"
    echo "which make: `which make 2>/dev/null`"
    echo "which cmake: `which cmake 2>/dev/null`"
    echo "root-config --f77: `root-config --f77 2>/dev/null`"
    echo "root-config --cc: `root-config --cc 2>/dev/null`"
    echo "root-config --cxx: `root-config --cxx 2>/dev/null`"
    echo "root-config --ld: `root-config --ld 2>/dev/null`"
    echo "root-config --features: `root-config --features 2>/dev/null`"
    echo "=== COMPILER VERSIONS ==="
    echo "*** gcc ***"
    gcc -v 2>&1
    echo "*** g++ ***"
    g++ -v 2>&1
    echo "*** gfortran ***"
    gfortran -v 2>&1
    echo "*** clang ***"
    clang -v 2>&1
    echo "*** clang++ ***"
    clang++ -v 2>&1
    echo "*** ld ***"
    ld -v 2>&1
    echo "*** cmake ***"
    cmake --version 2>&1
    if [ -r /etc/lsb-release ] ; then
      echo "*** /etc/lsb-release ***"
      cat /etc/lsb-release
    fi
    echo "=== END COMPILER VERSIONS ==="
    echo "=== DISK SPACE ==="
    df
    echo "=== END DISK SPACE ==="
    echo "=== MOUNTED VOLUMES ==="
    mount
    echo "=== END MOUNTED VOLUMES ==="
  ) >> $OUT 2>&1

}

# Shows a message reminding user to send the log files when asking for support
function ShowBugReportInfo() {
  echo ""
  echo -e "\033[41m\033[1;37mPlease attach both of the following files if asking for support:\033[m"
  echo ""
  echo "  $ERR"
  echo "  $OUT"
  echo ""
  echo -e "\033[41m\033[1;37mNote:\033[m if you are concerned about private information being saved in"
  echo '      logfiles, look at them and strip it off using a text editor'
  echo '      before sending them.'
  echo ""
}

# Module to fetch and compile ROOT
function ModuleRoot() {

  local SVN_LIST='https://root.cern.ch|http://root.cern.ch'
  local SVN_ROOT='/svn/root'

  Banner "Installing ROOT..."
  Swallow -f "Sourcing envvars" SourceEnvVars

  if [ ! -d "$ROOTSYS" ]; then
    Swallow -f "Creating ROOT directory" mkdir -p "$ROOTSYS"
  fi

  Swallow -f "Moving into ROOT directory" cd "$ROOTSYS"

  if [ "$DOWNLOAD_MODE" == '' ] || [ "$DOWNLOAD_MODE" == 'only' ] ; then

    #
    # Downloading ROOT from Git
    #

    local ROOTGit="${ROOTSYS}/../git"

    Swallow -f 'Creating ROOT Git local directory' mkdir -p "$ROOTGit"
    Swallow -f 'Moving into ROOT Git local directory' cd "$ROOTGit"
    [ ! -e "$ROOTGit/.git" ] && \
      Swallow -f 'Cloning ROOT Git repository (might take some time)' \
        git clone http://root.cern.ch/git/root.git .

    Swallow -f 'Updating list of remote ROOT Git branches' \
      git remote prune origin

    if [ "$ROOT_VER" == 'trunk' ] ; then
      ROOT_VER='master'
    fi
    Swallow -f "Checking out ROOT $ROOT_VER" git checkout "$ROOT_VER"
    Swallow "Updating ROOT $ROOT_VER from Git" git pull  # non-fatal
    Swallow -f 'Staging ROOT source in build directory' \
      rsync -avc --exclude '**/.git' "$ROOTGit"/ "$ROOTSYS"

  fi # end download

  if [ "$DOWNLOAD_MODE" == '' ] || [ "$DOWNLOAD_MODE" == 'no' ] ; then

    #
    # Build ROOT
    #

    Swallow -f 'Moving into ROOT build directory' cd "$ROOTSYS"

    # Choose correct configuration
    local ConfigOpts="--with-pythia6-uscore=SINGLE \
      --with-alien-incdir=$GSHELL_ROOT/include \
      --with-alien-libdir=$GSHELL_ROOT/lib \
      --with-monalisa-incdir="$GSHELL_ROOT/include" \
      --with-monalisa-libdir="$GSHELL_ROOT/lib" \
      --with-xrootd=$GSHELL_ROOT \
      --enable-minuit2 \
      --enable-roofit \
      --enable-soversion \
      --disable-bonjour \
      --enable-builtin-freetype"

    # Is --disable-fink available (Mac only)?
    if [ "`uname`" == 'Darwin' ] && \
       [ `./configure --help 2>/dev/null|grep -c finkdir` == 1 ]; then
      ConfigOpts="$ConfigOpts --disable-fink"
    fi

    case "$BUILD_MODE" in

      gcc)
        ConfigOpts="--with-f77=gfortran $ConfigOpts"
      ;;

      clang)
        ConfigOpts="--with-clang --with-f77=gfortran $ConfigOpts"
      ;;

      custom-gcc)
        ConfigOpts="--with-f77=$CUSTOM_GCC_PATH/bin/gfortran \
          --with-cc=$CUSTOM_GCC_PATH/bin/gcc \
          --with-cxx=$CUSTOM_GCC_PATH/bin/g++ \
          --with-ld=$CUSTOM_GCC_PATH/bin/g++ $ConfigOpts"
      ;;

    esac

    Swallow -f "Configuring ROOT" ./configure $ConfigOpts

    local AppendLDFLAGS AppendCPATH
    [ "$BUILDOPT_LDFLAGS" != '' ] && AppendLDFLAGS="LDFLAGS=$BUILDOPT_LDFLAGS"
    [ "$BUILDOPT_CPATH" != '' ] && AppendCPATH="CPATH=$BUILDOPT_CPATH"

    Swallow -f "Building ROOT" make -j$MJ $AppendLDFLAGS $AppendCPATH

    # To fix some problems during the creation of PARfiles in AliRoot
    if [ -e "$ROOTSYS/test/Makefile.arch" ]; then
      Swallow -f "Linking Makefile.arch" \
        ln -nfs "$ROOTSYS/test/Makefile.arch" "$ROOTSYS/etc/Makefile.arch"
    fi

  fi # end build

}

# Module to fetch and compile Geant3
function ModuleGeant3() {

  local SVN_LIST='https://root.cern.ch|http://root.cern.ch'
  local SVN_G3="/svn/geant3/"

  Banner "Installing Geant3..."
  Swallow -f "Sourcing envvars" SourceEnvVars

  if [ ! -d "$GEANT3DIR" ]; then
    Swallow -f "Creating Geant3 directory" mkdir -p "$GEANT3DIR"
  fi

  Swallow -f "Moving into Geant3 directory" cd "$GEANT3DIR"

  if [ "$DOWNLOAD_MODE" == '' ] || [ "$DOWNLOAD_MODE" == 'only' ] ; then

    #
    # Download Geant3
    #

    # Different behaviors if it is trunk or not
    if [ "$G3_VER" == "trunk" ]; then
      # Trunk: download if needed, update to latest if already present
      if [ ! -f "Makefile" ]; then
        # We have to download it
        Swallow -f "Downloading Geant3 trunk" \
          MultiSvn "$SVN_LIST" co "@SERVER@$SVN_G3/trunk" .
      else
        # We just have to update it
        Swallow -f "Updating Geant3 to latest trunk" svn up --non-interactive
      fi
    else
      # No trunk: just download, never update
      if [ ! -f "Makefile" ]; then
        Swallow -f "Downloading Geant3 $G3_VER" \
          MultiSvn "$SVN_LIST" co "@SERVER@$SVN_G3/tags/$G3_VER" .
      fi
    fi

  fi # end download

  if [ "$DOWNLOAD_MODE" == '' ] || [ "$DOWNLOAD_MODE" == 'no' ] ; then

    #
    # Build Geant3
    #

    Swallow -f "Building Geant3" make

  fi

}

# Module to fetch, update and compile AliRoot
function ModuleAliRoot() {

  #local SVN_ALIROOT="https://svn.cern.ch/reps/AliRoot"
  local SVN_ALIROOT="http://svn.cern.ch/guest/AliRoot"

  Banner "Installing AliRoot..."
  Swallow -f "Sourcing envvars" SourceEnvVars

  if [ ! -d "$ALICE_ROOT" ]; then
    Swallow -f "Creating AliRoot source directory" mkdir -p "$ALICE_ROOT"
  fi

  if [ ! -d "$ALICE_BUILD" ]; then
    Swallow -f "Creating AliRoot build directory" mkdir -p "$ALICE_BUILD"
  fi


  if [ "$DOWNLOAD_MODE" == '' ] || [ "$DOWNLOAD_MODE" == 'only' ] ; then

    #
    # Download AliRoot
    #

    Swallow -f "Moving into AliRoot source directory" cd "$ALICE_ROOT"
 
    # Different behaviors if it is trunk or not
    if [ "$ALICE_VER" == "trunk" ]; then
      # Trunk: download if needed, update to latest if already present
      if [ ! -d "STEER" ]; then
        # We have to download it
        Swallow -f "Downloading AliRoot trunk" svn co $SVN_ALIROOT/trunk .
      else
        # We just have to update it
        Swallow -f "Updating AliRoot to latest trunk" svn up --non-interactive
      fi
    else
      # No trunk: just download, never update
      if [ ! -d "STEER" ]; then
        Swallow -f "Downloading AliRoot $ALICE_VER" \
          svn co $SVN_ALIROOT/tags/$ALICE_VER .
      fi
    fi

  fi # end download

  if [ "$DOWNLOAD_MODE" == '' ] || [ "$DOWNLOAD_MODE" == 'no' ] ; then

    #
    # Build AliRoot
    #

    Swallow -f "Moving into AliRoot build directory" cd "$ALICE_BUILD"

    # Assemble cmake command
    if [ ! -e "Makefile" ]; then

      if [ "$BUILD_MODE" == 'clang' ]; then

        # Configuration for clang -- don't choose linker
        Swallow -f "Bootstrapping AliRoot build with cmake (for Clang)" \
          cmake "$ALICE_ROOT" \
            -DCMAKE_C_COMPILER=`root-config --cc` \
            -DCMAKE_CXX_COMPILER=`root-config --cxx` \
            -DCMAKE_Fortran_COMPILER=`root-config --f77`

      elif [ "$BUILDOPT_LDFLAGS" != '' ]; then

        # Special configuration for latest Ubuntu/Linux Mint
        Swallow -f "Bootstrapping AliRoot build with cmake (using LDFLAGS)" \
          cmake "$ALICE_ROOT" \
            -DCMAKE_C_COMPILER=`root-config --cc` \
            -DCMAKE_CXX_COMPILER=`root-config --cxx` \
            -DCMAKE_Fortran_COMPILER=`root-config --f77` \
            -DCMAKE_MODULE_LINKER_FLAGS="$BUILDOPT_LDFLAGS" \
            -DCMAKE_SHARED_LINKER_FLAGS="$BUILDOPT_LDFLAGS" \
            -DCMAKE_EXE_LINKER_FLAGS="$BUILDOPT_LDFLAGS"

      else

        # Any other configuration (no linker)
        Swallow -f "Bootstrapping AliRoot build with cmake" \
          cmake "$ALICE_ROOT" \
            -DCMAKE_C_COMPILER=`root-config --cc` \
            -DCMAKE_CXX_COMPILER=`root-config --cxx` \
            -DCMAKE_Fortran_COMPILER=`root-config --f77`

      fi

    fi

    SwallowProgress -f "Building AliRoot" make -j$MJ

    Swallow -f "Symlinking AliRoot include directory" \
      ln -nfs "$ALICE_BUILD"/include "$ALICE_ROOT"/include

    Swallow -f "Sourcing envvars" SourceEnvVars

    if [ "$DISPLAY" != "" ]; then
      # Non-fatal
      Swallow "Testing ROOT with AliRoot libraries" \
        root -l -q "$ALICE_ROOT"/macros/loadlibs.C
    fi

  fi # end build

}

# Cmake progress
function SwallowProgress() {

  local BGPID PCT PCT_FMT OP FATAL

  # Abort on error?
  if [ "$1" == "-f" ]; then
    FATAL=1
    shift
  else
    FATAL=0
  fi

  OP="$1"
  shift

  SwallowStart "$OP" "$@"
  TSSTART=$(date +%s)

  #( $@ > "$SWALLOW_LOG".out 2> "$SWALLOW_LOG".err ) &
  "$@" >> "$OUT" 2>> "$ERR" &
  BGPID=$!

  while ps 2> /dev/null | grep -v grep | grep $BGPID > /dev/null 2>&1
  do

    # Parse current percentage
    PCT=$( grep --text '%]' "$OUT" | \
      perl -ne '/\[\s*([0-9]{1,3})%\]/; print "$1\n"' | tail -n1 )

    # Show progress
    SwallowStep "$OP" "$PCT" $TSSTART

    # Sleep
    sleep 1

  done

  # It has finished: check exitcode
  wait $BGPID
  RET=$?

  TSEND=$(date +%s)
  SwallowEnd "$OP" $FATAL $RET $TSSTART $TSEND "$@"

  if [ $RET != 0 ] && [ $FATAL == 1 ]; then
    LastLogLines -e "$OP"
    exit 1
  fi

}

# Clean up PROOF on Demand
function ModuleCleanPoD() {
  Banner 'Cleaning PROOF on Demand and VAF...'
  Swallow -f 'Sourcing environment variables' SourceEnvVars
  Swallow -f 'Removing PoD and VAF directory' rm -rf "$ALI_POD_PREFIX"
}

# Clean up AliEn
function ModuleCleanAliEn() {
  local AliEnDir
  Banner "Cleaning AliEn..."
  Swallow -f "Sourcing envvars" SourceEnvVars
  find "$ALICE_PREFIX" -name 'alien.v*' -and -type d -maxdepth 1 | \
  while read AliEnDir ; do
    AliEnVer=`basename "$AliEnDir"`
    AliEnVer=${AliEnVer:6}
    Swallow -f "Removing AliEn $AliEnVer" rm -rf "$AliEnDir"
  done
  Swallow -f "Removing symlink to latest AliEn $ALIEN_DIR" rm -f "$ALIEN_DIR"
}

# Clean up ROOT
function ModuleCleanRoot() {
  Banner "Cleaning ROOT..."
  Swallow -f "Sourcing envvars" SourceEnvVars
  Swallow -f "Checking if ROOT is really installed" [ -f "$ROOTSYS"/Makefile ]
  Swallow -f "Removing ROOT $ROOT_VER" rm -rf "$ROOTSYS"
}

# Clean up Geant3
function ModuleCleanGeant3() {
  Banner "Cleaning Geant3..."
  Swallow -f "Sourcing envvars" SourceEnvVars
  Swallow -f "Checking if Geant3 is really installed" \
    [ -f "$GEANT3DIR"/Makefile ]
  Swallow -f "Removing Geant3 $G3_VER" rm -rf "$GEANT3DIR"
}

# Clean up AliRoot
function ModuleCleanAliRoot() {
  Banner "Cleaning AliRoot..."
  Swallow -f "Sourcing envvars" SourceEnvVars
  Swallow -f "Checking if AliRoot is really installed" \
    [ -d "$ALICE_BUILD"/../build ]
  Swallow -f "Removing AliRoot build directory" rm -rf "$ALICE_BUILD"/../build
}

# Download URL $1 to file $2 using wget or curl
function Dl() {
  which curl > /dev/null 2>&1
  if [ $? == 0 ]; then
    curl -Lo "$2" "$1"
    return $?
  else
    wget -O "$2" "$1"
    return $?
  fi
}

# Install AliEn
function ModuleAliEn() {

  local ALIEN_TEMP_INST_DIR="/tmp/alien-temp-inst-$USER"
  local ALIEN_INSTALLER="$ALIEN_TEMP_INST_DIR/alien-installer"

  Banner "Installing AliEn..."
  Swallow -f "Creating temporary working directory" \
    mkdir -p "$ALIEN_TEMP_INST_DIR"
  local CURWD=`pwd`
  cd "$ALIEN_TEMP_INST_DIR"

  Swallow -f "Sourcing envvars" SourceEnvVars
  Swallow -f "Downloading AliEn installer" \
    Dl http://alien.cern.ch/alien-installer "$ALIEN_INSTALLER"
  Swallow -f "Making AliEn installer executable" \
    chmod +x "$ALIEN_INSTALLER"

  local InstallMsg=''
  if [ "$ALIEN_INSTALL_TYPE" == 'compile' ] ; then
    InstallMsg='Compiling AliEn from sources'
  else
    InstallMsg='Installing AliEn binaries'
  fi

  Swallow -f "$InstallMsg" \
    "$ALIEN_INSTALLER" -install-dir "$ALIEN_DIR" -batch -notorrent \
    -no-certificate-check -type "$ALIEN_INSTALL_TYPE"

  cd "$CURWD"
  Swallow -f "Removing temporary working directory" rm -rf "$ALIEN_TEMP_INST_DIR"
}

# Install PROOF on Demand (always latest version)
function ModulePoD() {

  local PodSrc='http://pod.gsi.de/releases/pod/3.12/PoD-3.12-Source.tar.gz'
  local VafSrc='https://github.com/dberzano/virtual-analysis-facility/archive/master.zip'
  local Dst=`mktemp -d /tmp/alice-pod-inst-XXXXX 2> /dev/null`
  local PodSrcDir
  local VafSrcDir
  local LastCfVer
  local Your_alien_API_USER='REPLACE_IT_WITH_YOUR_ALIEN_USER_NAME'

  Banner 'Installing PROOF on Demand...'

  if [ ! -d "$Dst" ] ; then
    Swallow -f 'Asserting temporary working directory' false  # exits
  fi

  Swallow -f 'Downloading PROOF on Demand' Dl "$PodSrc" "${Dst}/podsrc.tar.gz"
  Swallow -f 'Unpacking PoD source' tar xzf "${Dst}/podsrc.tar.gz" -C "$Dst"

  # PoD Source directory discovery
  PodSrcDir=`ls -1d "${Dst}"/*/ 2> /dev/null`
  Swallow -f 'Moving into PoD source directory' cd "$PodSrcDir"

  # ALICE environment variables are needed from now on
  Swallow -f 'Sourcing environment variables' SourceEnvVars

  # Check for PoD prefix set
  if [ "$ALI_POD_PREFIX" == '' ] ; then
    Swallow -f 'Checking for PoD prefix in environment vars' false  # exits
  fi

  Swallow -f 'Creating PoD build directory' mkdir build
  Swallow -f 'Moving into PoD build directory' cd build
  Swallow -f 'Bootstrapping PoD installation' \
    cmake .. -DCMAKE_INSTALL_PREFIX="$ALI_POD_PREFIX"
  Swallow -f 'Compiling PoD' make -j$MJ
  Swallow -f 'Cleaning up previous PoD installation' rm -rf "$ALI_POD_PREFIX"
  Swallow -f 'Installing PoD' make install

  #
  # VAF part
  #

  Banner 'Installing VAF client...'

  # Download the VAF client and unpack
  Swallow -f 'Downloading VAF client' Dl "$VafSrc" "${Dst}/vaf.zip"
  Swallow -f 'Unpacking VAF client' unzip "${Dst}/vaf.zip" -d "$Dst"

  # VAF Source directory discovery
  VafSrcDir=`ls -1d "${Dst}"/virtual-analysis-facility*/ 2> /dev/null`
  Swallow -f 'Moving into VAF source directory' cd "$VafSrcDir"
  Swallow -f 'Installing VAF client' rsync -a client/bin "$ALI_POD_PREFIX"
  Swallow -f 'Installing VAF configuration for ALICE' \
    rsync -a client/config-samples/alice/ "$ALI_POD_PREFIX"/etc

  # Create global configuration matching current environment
  cat > "$ALI_POD_PREFIX/etc/local.before" 2> /dev/null <<_EoF_
# Automatically generated: you should not touch this file!
export UseCvmfsLocally=0
export AliceEnv="$ENVSCRIPT"
export VafConf_LocalPodLocation="$ALI_POD_PREFIX"
_EoF_
  Swallow -f 'Generating global VAF configuration' [ $? == 0 ]

  # Backup previous user's configuration if exists
  if [ -e "$HOME/.vaf/common.before" ] ; then
    LastCfVer=`ls -1 common.before.* 2> /dev/null | \
      grep '^common.before\.[0-9]\+' | grep -o '[0-9]\+' | sort -n | tail -n1`
    if [ "$LastCfVer" == '' ] ; then
      LastCfVer='0'
    else
      let LastCfVer++
    fi
    Swallow -f 'Making a backup of current user VAF config file' \
      mv "$HOME/.vaf/common.before" "$HOME/.vaf/common.before.$LastCfVer"
  else
    Swallow -f 'Creating VAF configuration directory' mkdir -p "$HOME"/.vaf
  fi

  Swallow -f 'Checking if VAF config directory is OK' [ -d "$HOME"/.vaf ]

  # AliEn Username
  [ "$alien_API_USER" != '' ] && Your_alien_API_USER="$alien_API_USER"

  # Create sample configuration file
  cat > "$HOME/.vaf/common.before" 2> /dev/null <<_EoF_
# Your AliEn username
export alien_API_USER='$Your_alien_API_USER'

# The desired AliRoot version (all dependencies are automatically set).
# Use the same name you find on http://alimonitor.cern.ch/packages, just
# without the initial "VO_ALICE@AliRoot::"
export VafAliRootVersion='v5-04-81-AN'
_EoF_
  Swallow -f 'Creating VAF user configuration file' [ $? == 0 ]

  Swallow 'Cleaning temporary files' rm -rf "/tmp/alice-pod-inst-"*

}

# Module to create prefix directory
function ModulePrepare() {
  local TF
  Banner "Creating directory structure..."
  Swallow -f "Sourcing envvars" SourceEnvVars

  mkdir -p "$ALICE_PREFIX" 2> /dev/null

  if [ "$USER" == "root" ]; then
    Swallow -f "Creating ALICE software directory" [ -d "$ALICE_PREFIX" ]
    Swallow -f "Opening permissions of ALICE directory" \
      chmod 0777 "$ALICE_PREFIX"
  else
    TF="$ALICE_PREFIX/dummy_$RANDOM"
    touch "$TF" 2> /dev/null
    if [ $? != 0 ]; then
      Fatal "Not enough permissions: please run \"sudo $Cmd --prepare\""
    fi
    rm "$TF"
  fi

}

# Fatal error
function Fatal() {
  echo -e "\033[31m$1\033[m"
  exit 1
}

# Remove old logs
function RemoveLogs() {
  rm -f "$SWALLOW_LOG".out "$SWALLOW_LOG".err
}

# Prints out a nice help
function Help() {
  local Cmd='bash <(curl -fsSL http://cern.ch/go/NcS7)'
  local C="\033[1m"
  local Z="\033[m"
  echo ""
  echo "alice-install.sh -- by Dario Berzano <dario.berzano@cern.ch>"
  echo ""
  echo "Tries to perform automatic installation of the ALICE framework."
  echo "Installation procedure follows exactly the steps described on:"
  echo ""
  echo -e "  ${C}http://newton.ph.unito.it/~berzano/w/doku.php?id=alice:compile${Z}"
  echo ""
  echo "Usage:"
  echo ""

  echo "  To create dirs (do it only the first time, as root if needed):"
  echo -e "    ${C}[sudo|su -c] $Cmd --prepare${Z}"
  echo ""

  echo "  To build/install/update something (multiple choices allowed):"
  echo -e "    ${C}$Cmd [--alien] [--root] [--geant3] [--aliroot] [--ncores <n>] [--compiler [gcc|clang|/prefix/to/gcc]]${Z}"
  echo ""

  echo "  To build/install/update everything (do --prepare first):"
  echo -e "    ${C}$Cmd --all${Z}"
  echo ""

  echo "  To cleanup something (multiple choices allowed - data is erased!):"
  echo -e "    ${C}$Cmd [--clean-root] [--clean-geant3] [--clean-aliroot]${Z}"
  echo ""

  echo "  To cleanup everything (except AliEn):"
  echo -e "    ${C}$Cmd --clean-all${Z}"
  echo ""

  echo "  You can cleanup then install like this:"
  echo -e "    ${C}$Cmd --clean-root --root --ncores 2${Z}"
  echo ""

  echo "  To prepare some debug information for your system:"
  echo -e "    ${C}$Cmd --bugreport${Z}"

  echo "  The --compiler option is not mandatory; you can either specify gcc or"
  echo "  clang, or the prefix to a custom GCC installation."
  echo ""

  echo "  Note that build/install/update as root user is disallowed."
  echo "  With optional --ncores <n> you specify the number of parallel builds."
  echo "  If nothing is specified, the default value (#cores + 1) is used."
  echo ""

  echo "  You can also decide to download only, or build only (not for AliEn):"
  echo -e "    ${C}$Cmd [--all|...] [--no-download|--download-only]${Z}"
  echo ""

  SourceEnvVars > /dev/null 2> /dev/null
  if [ "$?" != 0 ]; then
    echo "Must be run from a directory containing alice-env.sh!"
    echo "Environment script was expected in:"
    echo ""
    echo "  $ENVSCRIPT"
  else

    local ROOT_STR="$ROOT_VER"
    local G3_STR="$G3_VER"
    local ALICE_STR="$ALICE_VER"

    if [ "$ROOT_VER" != "$ROOT_SUBDIR" ]; then
      ROOT_STR="$ROOT_VER (subdir: $ROOT_SUBDIR)"
    fi

    if [ "$G3_VER" != "$G3_SUBDIR" ]; then
      G3_STR="$G3_VER (subdir: $G3_SUBDIR)"
    fi

    if [ "$ALICE_VER" != "$ALICE_SUBDIR" ]; then
      ALICE_STR="$ALICE_VER (subdir: $ALICE_SUBDIR)"
    fi

    local BUILD_MODE_STR="$BUILD_MODE"
    if [ "$BUILD_MODE" == "custom-gcc" ]; then
      BUILD_MODE_STR="$BUILD_MODE (under $CUSTOM_GCC_PATH)"
    fi

    echo "ALICE environment is read from:"
    echo ""
    echo -e "  ${C}$ENVSCRIPT${Z}"
    echo ""
    echo "Software install directory (make with --prepare in the first place):"
    echo ""
    echo -e "  ${C}$ALICE_PREFIX${Z}"
    echo ""
    echo "Versions of software that will be installed or cleaned up:"
    echo ""
    echo "  AliEn:   always the latest version"
    echo "  ROOT:    $ROOT_STR"
    echo "  Geant3:  $G3_STR"
    echo "  AliRoot: $ALICE_STR"
    echo ""
    echo -e "Selected compiler: ${C}$BUILD_MODE_STR${Z}"
    echo ""
    echo "Choose them in alice-env.sh script with TRIADS and N_TRIAD vars."
  fi
  echo ""

  # Error message, if any
  if [ "$1" != "" ]; then
    echo -e '>> \033[31m'$1'\033[m'
    echo ""
  fi

}

# Detects proper build options based on the current operating system
function DetectOsBuildOpts() {

  local KernelName=`uname -s`
  local VerFile='/etc/lsb-release'
  local OsName
  local OsVer

  if [ "$KernelName" == 'Darwin' ]; then
    ALIEN_INSTALL_TYPE='user'
    OsVer=`uname -r | cut -d. -f1`
    if [ "$OsVer" -ge 11 ]; then
      # 11 = Lion (10.7)
      SUPPORTED_BUILD_MODES='clang custom-gcc'
    fi
    if [ "$OsVer" -ge 12 ]; then
      # 12 = Mountain Lion (10.8)
      BUILDOPT_CPATH='/usr/X11/include'  # XQuartz
    fi
  elif [ "$KernelName" == 'Linux' ]; then
    ALIEN_INSTALL_TYPE='compile'
    SUPPORTED_BUILD_MODES='gcc custom-gcc'
    OsName=`source $VerFile > /dev/null 2>&1 ; echo $DISTRIB_ID`
    OsVer=`source $VerFile > /dev/null 2>&1 ; echo $DISTRIB_RELEASE | tr -d .`
    if [ "$OsName" == 'Ubuntu' ] && [ "$OsVer" -ge 1110 ]; then
      BUILDOPT_LDFLAGS='-Wl,--no-as-needed'
    elif [ "$OsName" == 'LinuxMint' ] && [ "$OsVer" -ge 12 ]; then
      BUILDOPT_LDFLAGS='-Wl,--no-as-needed'
    fi
  fi

  BUILD_MODE=`echo $SUPPORTED_BUILD_MODES | awk '{print $1}'`

}

# Main function
function Main() {

  local DO_PREP=0
  local DO_POD=0
  local DO_ALIEN=0
  local DO_ROOT=0
  local DO_G3=0
  local DO_ALICE=0
  local DO_CLEAN_POD=0
  local DO_CLEAN_ALIEN=0
  local DO_CLEAN_ALICE=0
  local DO_CLEAN_ROOT=0
  local DO_CLEAN_G3=0
  local DO_BUGREPORT=0

  local N_INST=0
  local N_CLEAN=0
  local N_INST_CLEAN=0
  local N_SVN=0
  local PARAM

  # Detect proper build options
  DetectOsBuildOpts

  # Environment script: look for it in current dir
  ENVSCRIPT="$PWD/alice-env.sh"

  if [ ! -r "$ENVSCRIPT" ]; then
    Help
    exit 1
  fi

  # Parse parameters
  while [ $# -gt 0 ]; do
    if [ "${1:0:2}" == "--" ]; then
      PARAM="${1:2}"
      case "$PARAM" in

        #
        # Install targets
        #

        pod)
          DO_POD=1
        ;;

        alien)
          DO_ALIEN=1
        ;;

        root)
          DO_ROOT=1
        ;;

        geant3)
          DO_G3=1
        ;;

        aliroot)
          DO_ALICE=1
        ;;

        all)
          # No PoD by default (for now)
          DO_ALIEN=1
          DO_ROOT=1
          DO_G3=1
          DO_ALICE=1
        ;;

        #
        # Cleanup targets (AliEn is not to be cleaned up)
        #

        clean-pod)
          DO_CLEAN_POD=1
        ;;

        clean-alien)
          DO_CLEAN_ALIEN=1
        ;;

        clean-root)
          DO_CLEAN_ROOT=1
        ;;

        clean-geant3)
          DO_CLEAN_G3=1
        ;;

        clean-aliroot)
          DO_CLEAN_ALICE=1
        ;;

        clean-all)
          # Don't clean PoD by default (for now)
          DO_CLEAN_ALIEN=1
          DO_CLEAN_ROOT=1
          DO_CLEAN_G3=1
          DO_CLEAN_ALICE=1
        ;;

        #
        # Other targets
        #

        bugreport)
          DO_BUGREPORT=1
        ;;

        prepare)
          DO_PREP=1
        ;;

        ncores)
          NCORES="$2"
          expr "$NCORES" + 0 > /dev/null 2> /dev/null
          if [ $? != 0 ]; then
            Help "--ncores must be followed by a number greater than zero"
            exit 1
          fi
          shift
        ;;

        compiler)
          BUILD_MODE="$2"

          if [ "$BUILD_MODE" == '' ]; then
            Help "No compiler specified, use one of: $SUPPORTED_BUILD_MODES"
            exit 1
          elif [ "${BUILD_MODE:0:1}" == '/' ]; then
            BUILD_MODE='custom-gcc'
            CUSTOM_GCC_PATH="$2"
          fi

          shift

          # Is this build mode supported?
          local Found=0
          local B
          for B in $SUPPORTED_BUILD_MODES ; do
            if [ "$B" == "$BUILD_MODE" ]; then
              Found=1
              break
            fi
          done
          if [ "$Found" != 1 ]; then
            Help "Unsupported compiler: $BUILD_MODE, use one \
                 of: $SUPPORTED_BUILD_MODES"
            exit 1
          fi

        ;;

        download-only)
          DOWNLOAD_MODE='only'
        ;;

        no-download)
          DOWNLOAD_MODE='no'
        ;;

        *)
          Help "Unrecognized parameter: $1"
          exit 1
        ;;

      esac
    else
      Help "Unrecognized parameter: $1"
      exit 1
    fi
    shift
  done

  # How many build actions?
  let N_SVN=DO_ROOT+DO_G3+DO_ALICE
  let N_INST=DO_POD+DO_ALIEN+N_SVN
  let N_CLEAN=DO_CLEAN_POD+DO_CLEAN_ALIEN+DO_CLEAN_ROOT+DO_CLEAN_G3+DO_CLEAN_ALICE
  let N_INST_CLEAN=N_INST+N_CLEAN

  if [ $DO_PREP == 0 ] && [ $DO_BUGREPORT == 0 ] && \
     [ $N_INST_CLEAN == 0 ]; then
    Help "Nothing to do"
    exit 1
  elif [ $DO_PREP == 1 ] && [ $N_INST_CLEAN -gt 0 ]; then
    Help "Can't prepare and update/build/clean something at the same time"
    exit 1
  elif [ "$USER" == "root" ] && [ $N_INST_CLEAN -gt 0 ]; then
    Help "I'm refusing to continue the installation as root user"
    exit 1
  fi

  # Remove spurious log files left
  RemoveLogs

  # Prepare bugreport. This is always done. If --bugreport requested, quit
  # after preparing it, without deleting logfiles
  PrepareBugReport
  if [ $DO_BUGREPORT == 1 ]; then
    echo ""
    echo "Bug report information collected."
    ShowBugReportInfo
    return 0
  fi

  # Where are the logfiles?
  echo ""
  echo "Installation log files can be consulted on:"
  echo ""
  echo -e "  \033[34mstderr:\033[m $ERR"
  echo -e "  \033[34mstdout:\033[m $OUT"

  # Perform required actions
  if [ $DO_PREP == 1 ]; then
    ModulePrepare
  else
    SourceEnvVars > /dev/null 2>&1
    echo ""

    if [ $MJ == 1 ]; then
      echo "Building on single core (no parallel build)"
    else
      echo "Building using $MJ parallel threads"
    fi

    # Ask to accept all SVN certificates at the beginning
    if [ $N_SVN -gt 0 ]; then
      InteractiveAcceptSvn
      Banner 'Non-interactive installation begins: go get some tea and scones'
    fi

    # All modules
    [ $DO_CLEAN_POD   == 1 ] && ModuleCleanPoD
    [ $DO_POD         == 1 ] && ModulePoD
    [ $DO_CLEAN_ALIEN == 1 ] && ModuleCleanAliEn
    [ $DO_ALIEN       == 1 ] && ModuleAliEn
    [ $DO_CLEAN_ROOT  == 1 ] && ModuleCleanRoot
    [ $DO_ROOT        == 1 ] && ModuleRoot
    [ $DO_CLEAN_G3    == 1 ] && ModuleCleanGeant3
    [ $DO_G3          == 1 ] && ModuleGeant3
    [ $DO_CLEAN_ALICE == 1 ] && ModuleCleanAliRoot
    [ $DO_ALICE       == 1 ] && ModuleAliRoot
  fi

  # Remove logs: if we are here, everything went right, so no need to see the
  # logs
  RemoveLogs

  echo ""
}

Main "$@"
