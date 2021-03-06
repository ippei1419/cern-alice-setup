#
# alice-env.sh - by Dario Berzano <dario.berzano@cern.ch>
#
# This script is meant to be sourced in order to prepare the environment to run
# ALICE Offline Framework applications (AliEn, ROOT, Geant 3 and AliRoot).
#
# On a typical setup, only the first lines of this script ought to be changed.
#
# This script was tested under Ubuntu and Mac OS X.
#
# For updates: http://newton.ph.unito.it/~berzano/w/doku.php?id=alice:compile
#

#
# Customizable variables
#

# If the specified file exists, settings are read from there; elsewhere they
# are read directly from this file
if [ -r "$HOME/.alice-env.conf" ]; then
  source "$HOME/.alice-env.conf"
else

  # Installation prefix of everything
  export ALICE_PREFIX="/opt/alice"

  # By uncommenting this line, alien-token-init will automatically use the
  # variable as your default AliEn user without explicitly specifying it after
  # the command
  #export alien_API_USER="myalienusername"

  # Triads in the form "root geant3 aliroot". Index starts from 1, not 0.
  # More information: http://aliceinfo.cern.ch/Offline/AliRoot/Releases.html
  TRIAD[1]="v5-34-05 v1-14 trunk"
  TRIAD[2]="trunk trunk trunk"
  # ...add more "triads" here without skipping array indices...

  # This is the "triad" that will be selected in non-interactive mode.
  # Set it to the number of the array index of the desired "triad"
  export N_TRIAD=1

fi

################################################################################
#                                                                              #
#   * * * BEYOND THIS POINT THERE IS LIKELY NOTHING YOU NEED TO MODIFY * * *   #
#                                                                              #
################################################################################

#
# Unmodifiable variables
#

# This one is automatically set by SVN; the regex extracts the sole revnum
export ALICE_ENV_REV=$(echo '$Rev$' | \
  perl -ne '/\$Rev:\s+([0-9]+)/; print "$1"')

# Remote URL of this very script
export ALICE_ENV_URL="http://db-alice-analysis.googlecode.com/svn/trunk/ali-inst/alice-env.sh"

# File that holds the timestamp of last check
export ALICE_ENV_LASTCHECK="/tmp/alice-env-lastcheck-$USER"

#
# Functions
#

# Shows the user a list of configured AliRoot triads. The chosen triad number is
# saved in the external variable N_TRIAD. A N_TRIAD of 0 means to clean up the
# environment
function AliMenu() {

  local C R M

  M="Please select an AliRoot triad in the form \033[35mROOT Geant3"
  M="$M AliRoot\033[m (you can also\nsource with \033[33m-n\033[m to skip"
  M="$M this menu, or with \033[33m-c\033[m to clean the environment):"

  echo -e "\n$M\n"
  for ((C=1; $C<=${#TRIAD[@]}; C++)); do
    echo -e "  \033[36m($C)\033[m "$(NiceTriad ${TRIAD[$C]})
  done
  echo "";
  echo -e "  \033[36m(0)\033[m \033[33mClear environment\033[m"
  while [ 1 ]; do
    echo ""
    echo -n "Your choice: "
    read -n1 N_TRIAD
    echo ""
    expr "$N_TRIAD" + 0 > /dev/null 2>&1
    R=$?
    if [ "$N_TRIAD" != "" ]; then
      if [ $R -eq 0 ] || [ $R -eq 1 ]; then
        if [ "$N_TRIAD" -ge 0 ] && [ "$N_TRIAD" -lt $C ]; then
          break
        fi
      fi
    fi
    echo "Invalid choice."
  done

}

# Checks periodically (twice a day) if there is an update to this script
function AliCheckUpdate() {

  local NOWTS THENTS DELTAS CUR_REV RET

  RET=0

  THENTS=$(cat "$ALICE_ENV_LASTCHECK" 2> /dev/null)
  [ "$THENTS" == "" ] && THENTS=0

  NOWTS=$(date +%s)

  let DELTAS=NOWTS-THENTS

  if [ $DELTAS -gt 43200 ]; then

    CUR_REV=$( LANG=C svn info "$ALICE_ENV_URL" 2> /dev/null | \
      grep -i 'last changed rev' | cut -d':' -f2 )
    CUR_REV=$(expr $CUR_REV + 0 2> /dev/null)

    if [ $? == 0 ]; then
      # svn info succeeded: compare versions
      if [ $CUR_REV -gt $ALICE_ENV_REV ]; then
        echo ""
        echo -e "\033[41m\033[37m!!! Update of this script is needed !!!\033[m"
        echo ""
        echo "Do the following:"
        echo ""
        echo "cd $ALICE_PREFIX"
        echo "svn export $ALICE_ENV_URL"
        echo "source $(basename $ALICE_ENV_URL)"
        echo ""
        RET=1
      fi
    fi

    # Recheck in one hour
    let NOWTS=NOWTS-43200+3600
    echo $NOWTS > "$ALICE_ENV_LASTCHECK"

  else
    # Write check date on file, if wrong
    [ $DELTAS -le 0 ] && echo $NOWTS > "$ALICE_ENV_LASTCHECK"
  fi

  return $RET
}

# Removes directories from the specified PATH-like variable that contain the
# given files. Variable is the first argument and it is passed by name, without
# the dollar sign; subsequent arguments are the files to search for
function AliRemovePaths() {

  local VARNAME=$1
  shift
  local DIRS=`eval echo \\$$VARNAME`
  local NEWDIRS=""
  local OIFS="$IFS"
  local D F KEEPDIR
  IFS=:

  for D in $DIRS
  do
    KEEPDIR=1
    if [ -d "$D" ]; then
      for F in $@
      do
        if [ -e "$D/$F" ]; then
          KEEPDIR=0
          break
        fi
      done
    else
      KEEPDIR=0
    fi
    if [ $KEEPDIR == 1 ]; then
      [ "$NEWDIRS" == "" ] && NEWDIRS="$D" || NEWDIRS="$NEWDIRS:$D"
    fi
  done

  IFS="$OIFS"

  eval export $VARNAME="$NEWDIRS"

}

# Cleans leading, trailing and double colons from the variable whose name is
# passed as the only argument of the string
function AliCleanPathList() {
  local VARNAME="$1"
  local STR=`eval echo \\$$VARNAME`
  local PREV_STR
  while [ "$PREV_STR" != "$STR" ]; do
    PREV_STR="$STR"
    STR=`echo "$STR" | sed s/::/:/g`
  done
  STR=${STR#:}
  STR=${STR%:}
  eval export $VARNAME=\"$STR\"
}

# Cleans up the environment from previously set (DY)LD_LIBRARY_PATH and PATH
# variables
function AliCleanEnv() {
  AliRemovePaths PATH alien_cp aliroot root
  AliRemovePaths LD_LIBRARY_PATH libCint.so libSTEER.so libXrdSec.so \
    libgeant321.so
  AliRemovePaths DYLD_LIBRARY_PATH libCint.so libSTEER.so libXrdSec.so \
    libgeant321.so
  AliRemovePaths PYTHONPATH ROOT.py

  # Unset other environment variables and aliases
  unset MJ ALIEN_DIR GSHELL_ROOT ROOTSYS ALICE ALICE_ROOT ALICE_BUILD \
    ALICE_TARGET GEANT3DIR X509_CERT_DIR ALICE ALI_POD_PREFIX
}

# Sets the number of parallel workers for make to the number of cores plus one
# in external variable MJ
function AliSetParallelMake() {
  MJ=`grep -c bogomips /proc/cpuinfo 2> /dev/null`
  [ "$?" != 0 ] && MJ=`sysctl hw.ncpu | cut -b10 2> /dev/null`
  # If MJ is NaN, "let" treats it as "0": always fallback to 1 core
  let MJ++
  export MJ
}

# Exports variables needed to run AliRoot, based on the selected triad
function AliExportVars() {

  #
  # PROOF on Demand
  #

  export ALI_POD_PREFIX="$ALICE_PREFIX/pod"
  export PATH="$ALI_POD_PREFIX/bin:$PATH"

  #
  # AliEn
  #

  export ALIEN_DIR="$ALICE_PREFIX/alien"
  export X509_CERT_DIR="$ALIEN_DIR/globus/share/certificates"

  # AliEn source installation uses a different destination directory
  [ -d "$X509_CERT_DIR" ] || X509_CERT_DIR="$ALIEN_DIR/api/share/certificates"

  export GSHELL_ROOT="$ALIEN_DIR/api"
  export PATH="$PATH:$GSHELL_ROOT/bin"
  export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$GSHELL_ROOT/lib"
  export DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH:$GSHELL_ROOT/lib"

  #
  # ROOT
  #

  export ROOTSYS="$ALICE_PREFIX/root/$ROOT_SUBDIR"
  export PATH="$ROOTSYS/bin:$PATH"
  export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$ROOTSYS/lib"
  if [ -e "$ROOTSYS/lib/ROOT.py" ]; then
    # PyROOT support
    export PYTHONPATH="$ROOTSYS/lib:$PYTHONPATH"
  fi

  #
  # AliRoot
  #

  export ALICE="$ALICE_PREFIX"

  # Let's detect AliRoot CMake builds
  if [ ! -e "$ALICE_PREFIX/aliroot/$ALICE_SUBDIR/Makefile" ]; then
    export ALICE_ROOT="$ALICE_PREFIX/aliroot/$ALICE_SUBDIR/src"
    export ALICE_BUILD="$ALICE_PREFIX/aliroot/$ALICE_SUBDIR/build"
  else
    export ALICE_ROOT="$ALICE_PREFIX/aliroot/$ALICE_SUBDIR"
    export ALICE_BUILD="$ALICE_ROOT"
  fi

  export ALICE_TARGET=`root-config --arch 2> /dev/null`
  export PATH="$PATH:${ALICE_BUILD}/bin/tgt_${ALICE_TARGET}"
  export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:${ALICE_BUILD}/lib/tgt_${ALICE_TARGET}"
  export DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH:${ALICE_BUILD}/lib/tgt_${ALICE_TARGET}"

  #
  # Geant 3
  #

  export GEANT3DIR="$ALICE_PREFIX/geant3/$G3_SUBDIR"
  export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$GEANT3DIR/lib/tgt_${ALICE_TARGET}"
 
}

# Prints out the ALICE paths. In AliRoot, the SVN revision number is also echoed
function AliPrintVars() {

  local WHERE_IS_G3 WHERE_IS_ALIROOT WHERE_IS_ROOT WHERE_IS_ALIEN \
    WHERE_IS_ALISRC WHERE_IS_ALIINST ALIREV MSG LEN I
  local NOTFOUND='\033[31m<not found>\033[m'

  # Check if Globus certificate is expiring soon
  local CERT="$HOME/.globus/usercert.pem"
  which openssl > /dev/null 2>&1
  if [ $? == 0 ]; then
    if [ -r "$CERT" ]; then
      openssl x509 -in "$CERT" -noout -checkend 0 > /dev/null 2>&1
      if [ $? == 1 ]; then
        MSG="Your certificate has expired"
      else
        openssl x509 -in "$CERT" -noout -checkend 604800 > /dev/null 2>&1
        if [ $? == 1 ]; then
          MSG="Your certificate is going to expire in less than one week"
        fi
      fi
    else
      MSG="Can't find certificate $CERT"
    fi
  fi

  # Print a message if an error checking the certificate has occured
  if [ "$MSG" != "" ]; then
    echo -e "\n\033[41m\033[37m!!! ${MSG} !!!\033[m"
  fi

  # Detect Geant3 installation path
  if [ -x "$GEANT3DIR/lib/tgt_$ALICE_TARGET/libgeant321.so" ]; then
    WHERE_IS_G3="$GEANT3DIR"
  else
    WHERE_IS_G3="$NOTFOUND"
  fi

  # Detect AliRoot source location
  if [ -r "$ALICE_ROOT/CMakeLists.txt" ] || [ -r "$ALICE_ROOT/Makefile" ]; then
    WHERE_IS_ALISRC="$ALICE_ROOT"
  else
    WHERE_IS_ALISRC="$NOTFOUND"
  fi

  # Detect AliRoot build/install location
  if [ -r "$ALICE_BUILD/bin/tgt_$ALICE_TARGET/aliroot" ]; then
    WHERE_IS_ALIINST="$ALICE_BUILD"
    # Try to fetch svn revision number
    ALIREV=$(cat "$ALICE_BUILD/include/ARVersion.h" 2>/dev/null |
      perl -ne 'if (/ALIROOT_SVN_REVISION\s+([0-9]+)/) { print "$1"; }')
    [ "$ALIREV" != "" ] && \
      WHERE_IS_ALIINST="$WHERE_IS_ALIINST \033[33m(rev. $ALIREV)\033[m"
  else
    WHERE_IS_ALIINST="$NOTFOUND"
  fi

  # Detect ROOT location
  if [ -x "$ROOTSYS/bin/root.exe" ]; then
    WHERE_IS_ROOT="$ROOTSYS"
  else
    WHERE_IS_ROOT="$NOTFOUND"
  fi

  # Detect AliEn location
  if [ -x "$GSHELL_ROOT/bin/aliensh" ]; then
    WHERE_IS_ALIEN="$GSHELL_ROOT"
  else
    WHERE_IS_ALIEN="$NOTFOUND"
  fi

  # Detect PoD location
  if [ -e "$ALI_POD_PREFIX/PoD_env.sh" ]; then
    WHERE_IS_POD="$ALI_POD_PREFIX"
  else
    WHERE_IS_POD="$NOTFOUND"
  fi

  echo ""
  echo -e "  \033[36mPROOF on Demand\033[m  $WHERE_IS_POD"
  echo -e "  \033[36mAliEn\033[m            $WHERE_IS_ALIEN"
  echo -e "  \033[36mROOT\033[m             $WHERE_IS_ROOT"
  echo -e "  \033[36mGeant3\033[m           $WHERE_IS_G3"
  echo -e "  \033[36mAliRoot source\033[m   $WHERE_IS_ALISRC"
  echo -e "  \033[36mAliRoot build\033[m    $WHERE_IS_ALIINST"
  echo ""

}

# Separates version from directory, if triad is expressed in the form
# directory(version). If no (version) is expressed, dir is set to version for
# backwards compatiblity
function ParseVerDir() {

  local VERDIR="$1"
  local DIR_VAR="$2"
  local VER_VAR="$3"

  # Perl script to separate dirname/version
  local PERL='/^([^()]+)\((.+)\)$/ and '
  PERL="$PERL"' print "'$DIR_VAR'=$1 ; '$VER_VAR'=$2" or '
  PERL="$PERL"' print "'$DIR_VAR'='$VERDIR' ; '$VER_VAR'='$VERDIR'"'

  # Perl
  eval "unset $DIR_VAR $VER_VAR"
  eval `echo "$VERDIR" | perl -ne "$PERL"`

}

# Echoes a triad in a proper way, supporting the format directory(version) and
# also the plain old format where dir==ver for backwards compatiblity
function NiceTriad() {
  export D V
  local C=0
  for T in $@ ; do
    ParseVerDir $T D V
    if [ "$D" != "$V" ]; then
      echo -n "\033[35m$D\033[m ($V)"
    else
      echo -n "\033[35m$D\033[m"
    fi
    [ $C != 2 ] && echo -n ' / '
    let C++
  done
  unset D V
}

# Main function: takes parameters from the command line
function AliMain() {

  local C T
  local OPT_QUIET OPT_NONINTERACTIVE OPT_CLEANENV OPT_DONTUPDATE

  # Parse command line options
  while [ $# -gt 0 ]; do
    case "$1" in
      "-q") OPT_QUIET=1 ;;
      "-v") OPT_QUIET=0 ;;
      "-n") OPT_NONINTERACTIVE=1 ;;
      "-i") OPT_NONINTERACTIVE=0 ;;
      "-c") OPT_CLEANENV=1; ;;
      "-u") OPT_DONTUPDATE=1 ;;
    esac
    shift
  done

  # Always non-interactive+do not update when cleaning environment
  if [ "$OPT_CLEANENV" == 1 ]; then
    OPT_NONINTERACTIVE=1
    OPT_DONTUPDATE=1
    N_TRIAD=0
  fi

  # Check for updates
  #if [ "$OPT_DONTUPDATE" != 1 ]; then
  #  AliCheckUpdate
  #  if [ $? != 0 ]; then
  #    MSG="\033[35mEnvironment variables not loaded: to avoid checking for"
  #    MSG="${MSG} updates, source this\nscript with option \033[33m-u\033[m\n"
  #    echo -e "$MSG"
  #    return 0
  #  fi
  #fi

  [ "$OPT_NONINTERACTIVE" != 1 ] && AliMenu

  if [ $N_TRIAD -gt 0 ]; then
    C=0
    for T in ${TRIAD[$N_TRIAD]}
    do
      case $C in
        0) ROOT_VER=$T ;;
        1) G3_VER=$T ;;
        2) ALICE_VER=$T ;;
      esac
      let C++
    done

    # Separates directory name from version (backwards compatible)
    ParseVerDir $ROOT_VER  'ROOT_SUBDIR'  'ROOT_VER'
    ParseVerDir $G3_VER    'G3_SUBDIR'    'G3_VER'
    ParseVerDir $ALICE_VER 'ALICE_SUBDIR' 'ALICE_VER'

  else
    # N_TRIAD=0 means "clean environment"
    OPT_CLEANENV=1
  fi

  # Cleans up the environment from previous varaiables
  AliCleanEnv

  if [ "$OPT_CLEANENV" != 1 ]; then

    # Number of parallel workers (on variable MJ)
    AliSetParallelMake

    # Export all the needed variables
    AliExportVars

    # Prints out settings, if requested
    [ "$OPT_QUIET" != 1 ] && AliPrintVars

  else
    unset ALICE_PREFIX ROOT_VER G3_VER ALICE_VER ROOT_SUBDIR G3_SUBDIR \
      ALICE_SUBDIR
    if [ "$OPT_QUIET" != 1 ]; then
      echo -e "\033[33mALICE environment variables cleared\033[m"
    fi
  fi

  # Cleans up artifacts in paths
  AliCleanPathList LD_LIBRARY_PATH
  AliCleanPathList DYLD_LIBRARY_PATH
  AliCleanPathList PATH

}

#
# Entry point
#

AliMain "$@"
unset N_TRIAD TRIAD
unset ALICE_ENV_LASTCHECK ALICE_ENV_REV ALICE_ENV_URL
unset AliCleanEnv AliCleanPathList AliExportVars AliMain AliMenu AliPrintVars \
  AliRemovePaths AliSetParallelMake
