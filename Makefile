# Makefile for dRonin project
.DEFAULT_GOAL := help

WHEREAMI := $(dir $(lastword $(MAKEFILE_LIST)))
export ROOT_DIR := $(realpath $(WHEREAMI)/ )
export BUILD_ALL_DEPENDENCIES := $(BUILD_ALL_DEPENDENCIES)
# import macros common to all supported build systems
include $(ROOT_DIR)/make/system-id.mk

# configure some directories that are relative to wherever ROOT_DIR is located
TOOLS_DIR := $(ROOT_DIR)/tools
BUILD_DIR := $(ROOT_DIR)/build
DL_DIR := $(ROOT_DIR)/downloads

export RM := rm
export CCACHE_BIN := $(shell which ccache 2>/dev/null)

# import macros that are OS specific
include $(ROOT_DIR)/make/$(OSFAMILY).mk

# include the tools makefile
include $(ROOT_DIR)/make/tools.mk

# Function for converting an absolute path to one relative
# to the top of the source tree.
toprel = $(subst $(realpath $(ROOT_DIR))/,,$(abspath $(1)))

# Clean out undesirable variables from the environment and command-line
# to remove the chance that they will cause problems with our build
define SANITIZE_VAR
$(if $(filter-out undefined,$(origin $(1))),
  $(info *NOTE*      Sanitized $(2) variable '$(1)' from $(origin $(1)))
  MAKEOVERRIDES = $(filter-out $(1)=%,$(MAKEOVERRIDES))
  override $(1) :=
  unexport $(1)
)
endef

# These specific variables can influence gcc in unexpected (and undesirable) ways
SANITIZE_GCC_VARS := TMPDIR GCC_EXEC_PREFIX COMPILER_PATH LIBRARY_PATH
SANITIZE_GCC_VARS += CFLAGS CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH DEPENDENCIES_OUTPUT
SANITIZE_GCC_VARS += ARCHFLAGS
$(foreach var, $(SANITIZE_GCC_VARS), $(eval $(call SANITIZE_VAR,$(var),disallowed)))

# These specific variables used to be valid but now they make no sense
SANITIZE_DEPRECATED_VARS := USE_BOOTLOADER
$(foreach var, $(SANITIZE_DEPRECATED_VARS), $(eval $(call SANITIZE_VAR,$(var),deprecated)))

# Decide on a verbosity level based on the V= parameter
export AT := @

ifndef V
export V0    :=
export V1    := $(AT)
else ifeq ($(V), 0)
export V0    := $(AT)
export V1    := $(AT)
else ifeq ($(V), 1)
endif


FW_FILES :=
GITVERSION := $(shell git describe --always --dirty --abbrev=9)

ALL_BOARDS :=

include $(ROOT_DIR)/flight/targets/*/target-defs.mk

# OpenPilot GCS build configuration (debug | release)
GCS_BUILD_CONF ?= debug

# And the flight build configuration (debug | default | release)
export FLIGHT_BUILD_CONF ?= default

##############################
#
# Check that environmental variables are sane
#
##############################
# Checking for $(ANDROIDGCS_BUILD_CONF) to be sane
ifdef ANDROIDGCS_BUILD_CONF
 ifneq ($(ANDROIDGCS_BUILD_CONF), release)
  ifneq ($(ANDROIDGCS_BUILD_CONF), debug)
   $(error Only debug or release are allowed for ANDROIDGCS_BUILD_CONF)
  endif
 endif
endif

# Checking for $(GCS_BUILD_CONF) to be sane
ifdef GCS_BUILD_CONF
 ifneq ($(GCS_BUILD_CONF), release)
  ifneq ($(GCS_BUILD_CONF), debug)
   $(error Only debug or release are allowed for GCS_BUILD_CONF)
  endif
 endif
endif

ifdef FLIGHT_BUILD_CONF
 ifneq ($(FLIGHT_BUILD_CONF), release)
  ifneq ($(FLIGHT_BUILD_CONF), debug)
   ifneq ($(FLIGHT_BUILD_CONF), default)
    $(error Only debug or release are allowed for FLIGHT_BUILD_CONF)
   endif
  endif
 endif
endif

##############################
#
# Help instructions
#
##############################
.PHONY: help
help:
	@echo
	@echo "   This Makefile is known to work on Linux and Mac in a standard shell environment."
	@echo "   It also works on Windows by following the instructions in make/winx86/README.txt."
	@echo
	@echo "   Here is a summary of the available targets:"
	@echo
	@echo "   [Tool Installers]"
	@echo "     qt_sdk_install       - Install the Qt tools"
	@echo "     arm_sdk_install      - Install the GNU ARM gcc toolchain"
	@echo "     openocd_install      - Install the OpenOCD SWD/JTAG daemon"
	@echo "     zip_install          - Install Info-Zip compression tool"
	@echo "        \$$OPENOCD_FTDI     - Set to no in order not to install legacy FTDI support for OpenOCD."
	@echo "     stm32flash_install   - Install the stm32flash tool for unbricking boards"
	@echo "     dfuutil_install      - Install the dfu-util tool for unbricking F4-based boards"
	@echo "     android_sdk_install  - Install the Android SDK tools"
	@echo "     gtest_install        - Install the google unit test suite"
	@echo "     uncrustify_install   - Install the uncrustify code formatter"
	@echo "     openssl_install      - Install the openssl libraries on windows machines"	
	@echo "     sdl_install          - Install the SDL libraries"

	@echo
	@echo "   [Big Hammer]"
	@echo "     all                  - Generate UAVObjects, build openpilot firmware and gcs"
	@echo "     all_flight           - Build all firmware, bootloaders and bootloader updaters"
	@echo "     all_fw               - Build only firmware for all boards"
	@echo "     all_bl               - Build only bootloaders for all boards"
	@echo "     all_bu               - Build only bootloader updaters for all boards"
	@echo
	@echo "     all_clean            - Remove your build directory ($(BUILD_DIR))"
	@echo "     all_flight_clean     - Remove all firmware, bootloaders and bootloader updaters"
	@echo "     all_fw_clean         - Remove firmware for all boards"
	@echo "     all_bl_clean         - Remove bootlaoders for all boards"
	@echo "     all_bu_clean         - Remove bootloader updaters for all boards"
	@echo
	@echo "     all_<board>          - Build all available images for <board>"
	@echo "     all_<board>_clean    - Remove all available images for <board>"
	@echo
	@echo "     all_ut               - Build all unit tests"
	@echo "     all_ut_tap           - Run all unit tests and capture all TAP output to files"
	@echo "     all_ut_run           - Run all unit tests and dump TAP output to console"
	@echo
	@echo "   [Firmware]"
	@echo "     <board>              - Build firmware for <board>"
	@echo "                            supported boards are ($(ALL_BOARDS))"
	@echo "     fw_<board>           - Build firmware for <board>"
	@echo "                            supported boards are ($(FW_BOARDS))"
	@echo "     fw_<board>_clean     - Remove firmware for <board>"
	@echo "     fw_<board>_program   - Use OpenOCD + SWD/JTAG to write firmware to <board>"
	@echo "     fw_<board>_wipe      - Use OpenOCD + SWD/JTAG to wipe entire firmware section on <board>"
	@echo "     fw_<board>_debug     - Use OpenOCD + SWD/JTAG to setup a GDB server on <board>"
	@echo
	@echo "   [Bootloader]"
	@echo "     bl_<board>           - Build bootloader for <board>"
	@echo "                            supported boards are ($(BL_BOARDS))"
	@echo "     bl_<board>_clean     - Remove bootloader for <board>"
	@echo "     bl_<board>_program   - Use OpenOCD + SWD/JTAG to write bootloader to <board>"
	@echo
	@echo "   [Entire Flash]"
	@echo "     ef_<board>           - Build entire flash image for <board>"
	@echo "                            supported boards are ($(EF_BOARDS))"
	@echo "     ef_<board>_clean     - Remove entire flash image for <board>"
	@echo "     ef_<board>_program   - Use OpenOCD + SWD/JTAG to write entire flash image to <board>"
	@echo
	@echo "   [Bootloader Updater]"
	@echo "     bu_<board>           - Build bootloader updater for <board>"
	@echo "                            supported boards are ($(BU_BOARDS))"
	@echo "     bu_<board>_clean     - Remove bootloader updater for <board>"
	@echo
	@echo "   [Unit tests]"
	@echo "     ut_<test>            - Build unit test <test>"
	@echo "     ut_<test>_tap        - Run test and capture TAP output into a file"
	@echo "     ut_<test>_run        - Run test and dump TAP output to console"
	@echo
	@echo "   [Simulation]"
	@echo "     simulation           - Build host simulation firmware"
	@echo "     simulation_clean     - Delete all build output for the simulation"
	@echo
	@echo "   [GCS]"
	@echo "     gcs                  - Build the Ground Control System (GCS) application"
	@echo "        GCS_QMAKE_OPTS=     - Optional build flags with the following arguments:"
	@echo "           \"CONFIG+=LIGHTWEIGHT_GCS\"  - Build a lightweight GCS suitable for low-powered platforms"
	@echo "           \"CONFIG+=SDL\"              - Enable joystick and gamepad support"
	@echo "           \"CONFIG+=OSG\"              - Enable OpenSceneGraph support"
	@echo "           \"CONFIG+=KML\"              - Enable KML file support"
	@echo "     gcs_clean            - Remove the Ground Control System (GCS) application"
	@echo
	@echo "   [AndroidGCS]"
	@echo "     androidgcs           - Build the Ground Control System (GCS) application"
	@echo "     androidgcs_install   - Use ADB to install the Ground Control System (GCS) application"
	@echo "     androidgcs_run       - Run the Ground Control System (GCS) application"
	@echo "     androidgcs_clean     - Remove the Ground Control System (GCS) application"
	@echo
	@echo "   [UAVObjects]"
	@echo "     uavobjects           - Generate source files from the UAVObject definition XML files"
	@echo "     uavobjects_test      - parse xml-files - check for valid, duplicate ObjId's, ... "
	@echo
	@echo "   [Packaging]"
	@echo "     package_flight       - Build and package the dRonin flight firmware only"
	@echo "     package_all_compress - Build and package all dRonin firmware and software"
	@echo "     package_installer    - Builds a dRonin software installer"
	@echo
	@echo "   Notes:"
	@echo "     - packages will be placed in $(PACKAGE_DIR)"
	@echo
	@echo "   [Misc]"
	@echo "     uncrustify_flight FILE=<name> - Executes uncrustify to reformat a c source"
	@echo "                                     file according to the flight code style"
	@echo
	@echo "   Hint: Add V=1 to your command line to see verbose build output."
	@echo
	@echo "   Note: All tools will be installed into $(TOOLS_DIR)"
	@echo "         All build output will be placed in $(BUILD_DIR)"
	@echo

.PHONY: all
all: all_ground all_flight matlab

.PHONY: all_clean
all_clean:
	[ ! -d "$(BUILD_DIR)" ] || $(RM) -r "$(BUILD_DIR)"

$(DL_DIR):
	mkdir -p $@

$(TOOLS_DIR):
	mkdir -p $@

$(BUILD_DIR):
	mkdir -p $@

##############################
#
# GCS related components
#
##############################

USE_MSVC ?= NO
ifeq ($(USE_MSVC), YES)
QT_SPEC=win32-msvc2013
endif
.PHONY: all_ground
all_ground: gcs

ifndef WINDOWS
# unfortunately the silent linking command is broken on windows
ifeq ($(V), 1)
GCS_SILENT := 
else
GCS_SILENT := silent
endif
endif

.PHONY: gcs
gcs:  uavobjects
ifeq ($(USE_MSVC), NO)
	$(V1) mkdir -p $(BUILD_DIR)/ground/$@
	$(V1) ( cd $(BUILD_DIR)/ground/$@ && \
	  PYTHON=$(PYTHON) $(QMAKE) $(ROOT_DIR)/ground/gcs/gcs.pro -spec $(QT_SPEC) -r CONFIG+="$(GCS_BUILD_CONF) $(GCS_SILENT)" $(GCS_QMAKE_OPTS) && \
	  $(MAKE) --no-print-directory -w ; \
	)
else
	$(V1) mkdir -p $(BUILD_DIR)/ground/$@
	$(V1) ( cd $(BUILD_DIR)/ground/$@ && \
	  PYTHON=$(PYTHON) $(QMAKE) $(ROOT_DIR)/ground/gcs/gcs.pro -spec $(QT_SPEC) -r CONFIG+="$(GCS_BUILD_CONF) $(GCS_SILENT)" $(GCS_QMAKE_OPTS) && \
	  MAKEFLAGS= jom $(JOM_OPTIONS); \
	)
endif

.PHONY: gcs_clean
gcs_clean:
	$(V0) @echo " CLEAN      $@"
	$(V1) [ ! -d "$(BUILD_DIR)/ground/gcs" ] || $(RM) -r "$(BUILD_DIR)/ground/gcs"

ifndef WINDOWS
# unfortunately the silent linking command is broken on windows
ifeq ($(V), 1)
UAVOGEN_SILENT := 
else
UAVOGEN_SILENT := silent
endif
endif
.PHONY: uavobjgenerator
uavobjgenerator:
	$(V1) mkdir -p $(BUILD_DIR)/ground/$@
ifeq ($(USE_MSVC), NO)
	$(V1) ( cd $(BUILD_DIR)/ground/$@ && \
	  PYTHON=$(PYTHON) $(QMAKE) $(ROOT_DIR)/ground/uavobjgenerator/uavobjgenerator.pro -spec $(QT_SPEC) -r CONFIG+="debug $(UAVOGEN_SILENT)" && \
	  $(MAKE) --no-print-directory -w; \
	)
else
	$(V1) ( cd $(BUILD_DIR)/ground/$@ && \
	  PYTHON=$(PYTHON) $(QMAKE) $(ROOT_DIR)/ground/uavobjgenerator/uavobjgenerator.pro -spec $(QT_SPEC) -r CONFIG+="debug $(UAVOGEN_SILENT)" && \
	  MAKEFLAGS= jom $(JOM_OPTIONS); \
	)
endif

UAVOBJ_XML_DIR := $(ROOT_DIR)/shared/uavobjectdefinition
UAVOBJ_OUT_DIR := $(BUILD_DIR)/uavobject-synthetics

uavobjects: uavobjgenerator
	$(V1) mkdir -p $(UAVOBJ_OUT_DIR)
	$(V1) ( cd $(UAVOBJ_OUT_DIR) && \
	  $(UAVOBJGENERATOR) $(UAVOBJ_XML_DIR) $(ROOT_DIR) ; \
	)

uavobjects_test: uavobjgenerator
	$(V1) $(UAVOBJGENERATOR) -v -none $(UAVOBJ_XML_DIR) $(ROOT_DIR)

uavobjects_clean: uavobjects_armsoftfp_clean uavobjects_armhardfp_clean
	$(V0) @echo " CLEAN      $@"
	$(V1) [ ! -d "$(UAVOBJ_OUT_DIR)" ] || $(RM) -r "$(UAVOBJ_OUT_DIR)"

##############################
#
# Matlab related components
#
##############################

MATLAB_OUT_DIR := $(BUILD_DIR)/matlab
$(MATLAB_OUT_DIR):
	$(V1) mkdir -p $@

FORCE:
$(MATLAB_OUT_DIR)/LogConvert.m: $(MATLAB_OUT_DIR) uavobjects FORCE
	$(V1) $(PYTHON) $(ROOT_DIR)/make/scripts/version-info.py \
		--path=$(ROOT_DIR) \
		--template=$(BUILD_DIR)/uavobject-synthetics/matlab/LogConvert.m.pass1 \
		--outfile=$@ \
		--uavodir=$(ROOT_DIR)/shared/uavobjectdefinition

.PHONY: matlab
matlab: uavobjects $(MATLAB_OUT_DIR)/LogConvert.m

################################
#
# Android GCS related components
#
################################

ANDROIDGCS_BUILD_CONF ?= debug

# Build the output directory for the Android GCS build
ANDROIDGCS_OUT_DIR := $(BUILD_DIR)/androidgcs
$(ANDROIDGCS_OUT_DIR):
	$(V1) mkdir -p $@

# Build the asset directory for the android assets
ANDROIDGCS_ASSETS_DIR := $(ANDROIDGCS_OUT_DIR)/assets
$(ANDROIDGCS_ASSETS_DIR)/uavos:
	$(V1) mkdir -p $@

ifeq ($(V), 1)
ANT_QUIET := -d
ANDROID_SILENT := 
else
ANT_QUIET := -q
ANDROID_SILENT := -s
endif
.PHONY: androidgcs
androidgcs: $(ANDROIDGCS_OUT_DIR)/bin/androidgcs-$(ANDROIDGCS_BUILD_CONF).apk

$(ANDROIDGCS_OUT_DIR)/bin/androidgcs-$(ANDROIDGCS_BUILD_CONF).apk: uavo-collections_java
	$(V0) @echo " ANDROID   $(call toprel, $(ANDROIDGCS_OUT_DIR))"
	$(V1) mkdir -p $(ANDROIDGCS_OUT_DIR)
	$(V1) $(ANDROID) $(ANDROID_SILENT) update project --subprojects --target 'Google Inc.:Google APIs:19' --name androidgcs --path ./androidgcs
	$(V1) ant -f ./androidgcs/google-play-services_lib/build.xml \
		$(ANT_QUIET) debug               
	$(V1) ant -f ./androidgcs/build.xml \
		$(ANT_QUIET) \
		-Dout.dir="../$(call toprel, $(ANDROIDGCS_OUT_DIR)/bin)" \
		-Dgen.absolute.dir="$(ANDROIDGCS_OUT_DIR)/gen" \
		$(ANDROIDGCS_BUILD_CONF)

.PHONY: androidgcs_run
androidgcs_run: androidgcs_install
	$(V0) @echo " AGCS RUN "
	$(V1) $(ANDROID_ADB) shell am start -n org.dronin.androidgcs/.HomePage

.PHONY: androidgcs_install
androidgcs_install: $(ANDROIDGCS_OUT_DIR)/bin/androidgcs-$(ANDROIDGCS_BUILD_CONF).apk
	$(V0) @echo " AGCS INST "
	$(V1) $(ANDROID_ADB) install -r $(ANDROIDGCS_OUT_DIR)/bin/androidgcs-$(ANDROIDGCS_BUILD_CONF).apk

.PHONY: androidgcs_clean
androidgcs_clean:
	$(V0) @echo " CLEAN      $@"
	$(V1) [ ! -d "$(ANDROIDGCS_OUT_DIR)" ] || $(RM) -r "$(ANDROIDGCS_OUT_DIR)"

# We want to take snapshots of the UAVOs at each point that they change
# to allow the GCS to be compatible with as many versions as possible.
#
# Find the git hashes of each commit that changes uavobjects with:
#   git log --format=%h -- shared/uavobjectdefinition/ | head -n 6 | tr '\n' ' '
UAVO_GIT_VERSIONS := HEAD 

# All versions includes a pseudo collection called "working" which represents
# the UAVOs in the source tree
UAVO_ALL_VERSIONS := $(sort $(UAVO_GIT_VERSIONS) srctree)

# This is where the UAVO collections are stored
UAVO_COLLECTION_DIR := $(BUILD_DIR)/uavo-collections

# $(1) git hash of a UAVO snapshot
define UAVO_COLLECTION_GIT_TEMPLATE

# Make the output directory that will contain all of the synthetics for the
# uavo collection referenced by the git hash $(1)
$$(UAVO_COLLECTION_DIR)/$(1):
	$$(V1) mkdir -p $$(UAVO_COLLECTION_DIR)/$(1)

# Extract the snapshot of shared/uavobjectdefinition from git hash $(1)
$$(UAVO_COLLECTION_DIR)/$(1)/uavo-xml.tar: | $$(UAVO_COLLECTION_DIR)/$(1)
$$(UAVO_COLLECTION_DIR)/$(1)/uavo-xml.tar:
	$$(V0) @echo " UAVOTAR   $(1)"
	$$(V1) git archive $(1) -o $$@ -- shared/uavobjectdefinition/

# Extract the uavo xml files from our snapshot
$$(UAVO_COLLECTION_DIR)/$(1)/uavo-xml: $$(UAVO_COLLECTION_DIR)/$(1)/uavo-xml.tar
	$$(V0) @echo " UAVOUNTAR $(1)"
	$$(V1) rm -rf $$@
	$$(V1) mkdir -p $$@
	$$(V1) tar -C $$(call toprel, $$@) -xf $$(call toprel, $$<) || rm -rf $$@
endef

# Map the current working directory into the set of UAVO collections
$(UAVO_COLLECTION_DIR)/srctree:
	$(V1) mkdir -p $@

$(UAVO_COLLECTION_DIR)/srctree/uavo-xml: | $(UAVO_COLLECTION_DIR)/srctree
$(UAVO_COLLECTION_DIR)/srctree/uavo-xml: $(UAVOBJ_XML_DIR)
	$(V1) ln -sf $(ROOT_DIR) $(UAVO_COLLECTION_DIR)/srctree/uavo-xml

# $(1) git hash (or symbolic name) of a UAVO snapshot
define UAVO_COLLECTION_BUILD_TEMPLATE

# This leaves us with a (broken) symlink that points to the full sha1sum of the collection
$$(UAVO_COLLECTION_DIR)/$(1)/uavohash: $$(UAVO_COLLECTION_DIR)/$(1)/uavo-xml
        # Compute the sha1 hash for this UAVO collection
        # The sed bit truncates the UAVO hash to 16 hex digits
	$$(V1) $(PYTHON) $$(ROOT_DIR)/make/scripts/version-info.py \
			--path=$$(ROOT_DIR) \
			--uavodir=$$(UAVO_COLLECTION_DIR)/$(1)/uavo-xml/shared/uavobjectdefinition \
			--format='$$$${UAVOSHA1TXT}' | \
		sed -e 's|\(................\).*|\1|' > $$@

	$$(V0) @echo " UAVOHASH  $(1) ->" $$$$(cat $$(UAVO_COLLECTION_DIR)/$(1)/uavohash)

# Generate the java uavobjects for this UAVO collection
$$(UAVO_COLLECTION_DIR)/$(1)/java-build/java: $$(UAVO_COLLECTION_DIR)/$(1)/uavohash uavobjgenerator
	$$(V0) @echo " UAVOJAVA  $(1)   " $$$$(cat $$(UAVO_COLLECTION_DIR)/$(1)/uavohash)
	$$(V1) ( \
		mkdir -p $$(UAVO_COLLECTION_DIR)/$(1)/java-build && \
		cd $$(UAVO_COLLECTION_DIR)/$(1)/java-build && \
		$$(UAVOBJGENERATOR) -java $$(UAVO_COLLECTION_DIR)/$(1)/uavo-xml/shared/uavobjectdefinition $$(ROOT_DIR) ; \
	)

# Build a jar file for this UAVO collection
$$(UAVO_COLLECTION_DIR)/$(1)/java-build/uavobjects.jar: | $$(ANDROIDGCS_ASSETS_DIR)/uavos
$$(UAVO_COLLECTION_DIR)/$(1)/java-build/uavobjects.jar: $$(UAVO_COLLECTION_DIR)/$(1)/java-build/java
	$$(V0) @echo " UAVOJAR   $(1)   " $$$$(cat $$(UAVO_COLLECTION_DIR)/$(1)/uavohash)
	$$(V1) ( \
		HASH=$$$$(cat $$(UAVO_COLLECTION_DIR)/$(1)/uavohash) && \
		cd $$(UAVO_COLLECTION_DIR)/$(1)/java-build && \
		javac -source 1.6 -target 1.6 java/*.java \
		   $$(ROOT_DIR)/androidgcs/src/org/dronin/uavtalk/UAVDataObject.java \
		   $$(ROOT_DIR)/androidgcs/src/org/dronin/uavtalk/UAVObject*.java \
		   $$(ROOT_DIR)/androidgcs/src/org/dronin/uavtalk/UAVMetaObject.java \
		   -d . && \
		find ./org/dronin/uavtalk/uavobjects -type f -name '*.class' > classlist.txt && \
		jar cf tmp_uavobjects.jar @classlist.txt && \
		$$(ANDROID_DX) \
			--dex \
			--output $$(ANDROIDGCS_ASSETS_DIR)/uavos/$$$${HASH}.jar \
			tmp_uavobjects.jar && \
		ln -sf $$(ANDROIDGCS_ASSETS_DIR)/uavos/$$$${HASH}.jar uavobjects.jar \
	)


# Generate the matlab uavobjects for this UAVO collection
$$(UAVO_COLLECTION_DIR)/$(1)/matlab-build/matlab: $$(UAVO_COLLECTION_DIR)/$(1)/uavohash uavobjgenerator
	$$(V0) @echo " UAVOMATLAB $(1)  " $$$$(cat $$(UAVO_COLLECTION_DIR)/$(1)/uavohash)
	$$(V1) mkdir -p $$@
	$$(V1) ( \
		cd $$(UAVO_COLLECTION_DIR)/$(1)/matlab-build && \
		$$(UAVOBJGENERATOR) -matlab $$(UAVO_COLLECTION_DIR)/$(1)/uavo-xml/shared/uavobjectdefinition $$(ROOT_DIR) ; \
	)

# Build a jar file for this UAVO collection
$$(UAVO_COLLECTION_DIR)/$(1)/matlab-build/LogConvert.m: $$(UAVO_COLLECTION_DIR)/$(1)/matlab-build/matlab
	$$(V0) @echo " UAVOMAT   $(1)   " $$$$(cat $$(UAVO_COLLECTION_DIR)/$(1)/uavohash)
	$$(V1) ( \
		HASH=$$$$(cat $$(UAVO_COLLECTION_DIR)/$(1)/uavohash) && \
		cd $$(UAVO_COLLECTION_DIR)/$(1)/matlab-build && \
		$(PYTHON) $(ROOT_DIR)/make/scripts/version-info.py \
			--path=$$(ROOT_DIR) \
			--template=$$(UAVO_COLLECTION_DIR)/$(1)/matlab-build/matlab/LogConvert.m.pass1 \
		--outfile=$$@ \
		--uavodir=$$(UAVO_COLLECTION_DIR)/$(1)/uavo-xml/shared/uavobjectdefinition \
	)

endef

# One of these for each element of UAVO_GIT_VERSIONS so we can extract the UAVOs from git
$(foreach githash, $(UAVO_GIT_VERSIONS), $(eval $(call UAVO_COLLECTION_GIT_TEMPLATE,$(githash))))

# One of these for each UAVO_ALL_VERSIONS which includes the ones in the srctree
$(foreach githash, $(UAVO_ALL_VERSIONS), $(eval $(call UAVO_COLLECTION_BUILD_TEMPLATE,$(githash))))

.PHONY: uavo-collections_java
uavo-collections_java: $(foreach githash, $(UAVO_ALL_VERSIONS), $(UAVO_COLLECTION_DIR)/$(githash)/java-build/uavobjects.jar)

.PHONY: uavo-collections_matlab
uavo-collections_matlab: $(foreach githash, $(UAVO_ALL_VERSIONS), $(UAVO_COLLECTION_DIR)/$(githash)/matlab-build/LogConvert.m)

.PHONY: uavo-collections
uavo-collections: uavo-collections_java

.PHONY: uavo-collections_clean
uavo-collections_clean:
	$(V0) @echo " CLEAN  $(UAVO_COLLECTION_DIR)"
	$(V1) [ ! -d "$(UAVO_COLLECTION_DIR)" ] || $(RM) -r $(UAVO_COLLECTION_DIR)

##############################
#
# Flight related components
#
##############################

# Define some pointers to the various important pieces of the flight code
# to prevent these being repeated in every sub makefile
export MAKE_INC_DIR  := $(ROOT_DIR)/make
export PIOS          := $(ROOT_DIR)/flight/PiOS
export FLIGHTLIB     := $(ROOT_DIR)/flight/Libraries
export OPMODULEDIR   := $(ROOT_DIR)/flight/Modules
export OPUAVOBJ      := $(ROOT_DIR)/flight/UAVObjects
export OPUAVTALK     := $(ROOT_DIR)/flight/UAVTalk
export DOXYGENDIR    := $(ROOT_DIR)/Doxygen
export SHAREDAPIDIR  := $(ROOT_DIR)/shared/api
export OPUAVSYNTHDIR := $(BUILD_DIR)/uavobject-synthetics/flight

# $(1) = Canonical board name all in lower case (e.g. coptercontrol)
# $(2) = Unused
# $(3) = Short name for board (e.g. CC)
# $(4) = Host sim variant (e.g. posix)
# $(5) = Build output type (e.g. elf, exe)

.PHONY: simulation
simulation: sim_posix

# Legacy for people who were using the old target name
.PHONY: sim_posix_revolution
sim_posix_revolution: sim_posix

define SIM_TEMPLATE

.PHONY: sim_$(4)
sim_$(4): TARGET=sim_$(4)
sim_$(4): OUTDIR=$(BUILD_DIR)/$$(TARGET)
sim_$(4): BOARD_ROOT_DIR=$(ROOT_DIR)/flight/targets/$(1)
sim_$(4): uavobjects
	$(V1) mkdir -p $$(OUTDIR)/dep
	$(V1) cd $$(BOARD_ROOT_DIR)/fw && \
		$$(MAKE) --no-print-directory \
		--file=Makefile.$(4) \
		BOARD_NAME=$(1) \
		BOARD_SHORT_NAME=$(3) \
		BUILD_TYPE=sm \
		TCHAIN_PREFIX="" \
		REMOVE_CMD="$(RM)" \
		\
		ROOT_DIR=$(ROOT_DIR) \
		BOARD_ROOT_DIR=$$(BOARD_ROOT_DIR) \
		BOARD_INFO_DIR=$$(BOARD_ROOT_DIR)/board-info \
		TARGET=$$(TARGET) \
		OUTDIR=$$(OUTDIR) \
		\
		PIOS=$(PIOS).$(4) \
		\
		$$*

.PHONY: sim_$(4)_clean
sim_$(4)_clean: TARGET=sim_$(4)
sim_$(4)_clean: OUTDIR=$(BUILD_DIR)/$$(TARGET)
sim_$(4)_clean:
	$(V0) @echo " CLEAN      $$@"
	$(V1) [ ! -d "$$(OUTDIR)" ] || $(RM) -r "$$(OUTDIR)"
endef

# $(1) = Canonical board name all in lower case (e.g. coptercontrol)
# $(2) = Unused
# $(3) = Short name for board (e.g CC)
define FW_TEMPLATE
.PHONY: $(1) fw_$(1)
$(1): fw_$(1)_tlfw
fw_$(1): fw_$(1)_tlfw

FW_FILES += $(BUILD_DIR)/fw_$(1)/fw_$(1).tlfw

fw_$(1)_%: TARGET=fw_$(1)
fw_$(1)_%: OUTDIR=$(BUILD_DIR)/$$(TARGET)
fw_$(1)_%: BOARD_ROOT_DIR=$(ROOT_DIR)/flight/targets/$(1)
fw_$(1)_%: uavobjects_armsoftfp uavobjects_armhardfp
	$(V1) mkdir -p $$(OUTDIR)/dep
	$(V1) cd $$(BOARD_ROOT_DIR)/fw && \
		$$(MAKE) -r --no-print-directory \
		BOARD_NAME=$(1) \
		BOARD_SHORT_NAME=$(3) \
		BUILD_TYPE=fw \
		TCHAIN_PREFIX="$(ARM_SDK_PREFIX)" \
		REMOVE_CMD="$(RM)" OOCD_EXE="$(OPENOCD)" \
		\
		ROOT_DIR=$(ROOT_DIR) \
		BOARD_ROOT_DIR=$$(BOARD_ROOT_DIR) \
		BOARD_INFO_DIR=$$(BOARD_ROOT_DIR)/board-info \
		TARGET=$$(TARGET) \
		OUTDIR=$$(OUTDIR) \
		\
		$$*

.PHONY: $(1)_clean
$(1)_clean: fw_$(1)_clean
fw_$(1)_clean: TARGET=fw_$(1)
fw_$(1)_clean: OUTDIR=$(BUILD_DIR)/$$(TARGET)
fw_$(1)_clean:
	$(V0) @echo " CLEAN      $$@"
	$(V1) [ ! -d "$$(OUTDIR)" ] || $(RM) -r "$$(OUTDIR)"
endef

# $(1) = Canonical board name all in lower case (e.g. coptercontrol)
# $(2) = CPU arch (e.g. f1, f3, f4)
# $(3) = Short name for board (e.g CC)
define BL_TEMPLATE
.PHONY: bl_$(1)
bl_$(1): bl_$(1)_bin

FW_FILES += $(BUILD_DIR)/bl_$(1)/bl_$(1).bin

bl_$(1)_%: TARGET=bl_$(1)
bl_$(1)_%: OUTDIR=$(BUILD_DIR)/$$(TARGET)
bl_$(1)_%: BOARD_ROOT_DIR=$(ROOT_DIR)/flight/targets/$(1)
bl_$(1)_%: BLSRCDIR=$(ROOT_DIR)/flight/targets/bl
bl_$(1)_%: BLCOMMONDIR=$$(BLSRCDIR)/common
bl_$(1)_%: BLARCHDIR=$$(BLSRCDIR)/$(2)
bl_$(1)_%: BLBOARDDIR=$$(BOARD_ROOT_DIR)/bl
bl_$(1)_%:
	$(V1) mkdir -p $$(OUTDIR)/dep
	$(V1) cd $$(BLARCHDIR) && \
		$$(MAKE) -r --no-print-directory \
		BOARD_NAME=$(1) \
		BOARD_SHORT_NAME=$(3) \
		BUILD_TYPE=bl \
		TCHAIN_PREFIX="$(ARM_SDK_PREFIX)" \
		REMOVE_CMD="$(RM)" OOCD_EXE="$(OPENOCD)" \
		\
		ROOT_DIR=$(ROOT_DIR) \
		BOARD_ROOT_DIR=$$(BOARD_ROOT_DIR) \
		BOARD_INFO_DIR=$$(BOARD_ROOT_DIR)/board-info \
		TARGET=$$(TARGET) \
		OUTDIR=$$(OUTDIR) \
		BLCOMMONDIR=$$(BLCOMMONDIR) \
		BLARCHDIR=$$(BLARCHDIR) \
		BLBOARDDIR=$$(BLBOARDDIR) \
		\
		$$*

.PHONY: bl_$(1)_clean
bl_$(1)_clean: TARGET=bl_$(1)
bl_$(1)_clean: OUTDIR=$(BUILD_DIR)/$$(TARGET)
bl_$(1)_clean:
	$(V0) @echo " CLEAN      $$@"
	$(V1) [ ! -d "$$(OUTDIR)" ] || $(RM) -r "$$(OUTDIR)"
endef

# $(1) = Canonical board name all in lower case (e.g. coptercontrol)
# $(2) = Unused
# $(3) = Short name for board (e.g CC)
define BU_TEMPLATE
.PHONY: bu_$(1)
bu_$(1): bu_$(1)_tlfw

FW_FILES += $(BUILD_DIR)/bu_$(1)/bu_$(1).tlfw

bu_$(1)_%: TARGET=bu_$(1)
bu_$(1)_%: OUTDIR=$(BUILD_DIR)/$$(TARGET)
bu_$(1)_%: BOARD_ROOT_DIR=$(ROOT_DIR)/flight/targets/$(1)
bu_$(1)_%: BUSRCDIR=$(ROOT_DIR)/flight/targets/bu
bu_$(1)_%: BUCOMMONDIR=$$(BUSRCDIR)/common
bu_$(1)_%: BUARCHDIR=$$(BUSRCDIR)/$(2)
bu_$(1)_%: BUBOARDDIR=$$(BOARD_ROOT_DIR)/bu
bu_$(1)_%: bl_$(1)_bin
	$(V1) mkdir -p $$(OUTDIR)/dep
	$(V1) cd $$(BUARCHDIR) && \
		$$(MAKE) -r --no-print-directory \
		BOARD_NAME=$(1) \
		BOARD_SHORT_NAME=$(3) \
		BUILD_TYPE=bu \
		TCHAIN_PREFIX="$(ARM_SDK_PREFIX)" \
		REMOVE_CMD="$(RM)" OOCD_EXE="$(OPENOCD)" \
		\
		ROOT_DIR=$(ROOT_DIR) \
		BOARD_ROOT_DIR=$$(BOARD_ROOT_DIR) \
		BOARD_INFO_DIR=$$(BOARD_ROOT_DIR)/board-info \
		TARGET=$$(TARGET) \
		OUTDIR=$$(OUTDIR) \
		BUCOMMONDIR=$$(BUCOMMONDIR) \
		BUARCHDIR=$$(BUARCHDIR) \
		BUBOARDDIR=$$(BUBOARDDIR) \
		DOXYGENDIR=$(DOXYGENDIR) \
		\
		$$*

.PHONY: bu_$(1)_clean
bu_$(1)_clean: TARGET=bu_$(1)
bu_$(1)_clean: OUTDIR=$(BUILD_DIR)/$$(TARGET)
bu_$(1)_clean:
	$(V0) @echo " CLEAN      $$@"
	$(V1) [ ! -d "$$(OUTDIR)" ] || $(RM) -r "$$(OUTDIR)"
endef

# $(1) = Canonical board name all in lower case (e.g. coptercontrol)
# $(2) = Friendly board name
# $(3) = Short board name
# $(4) = yes for bootloader, no for no bootloader
define EF_TEMPLATE
.PHONY: ef_$(1)
ef_$(1): ef_$(1)_hex

FW_FILES += $(BUILD_DIR)/ef_$(1)/ef_$(1).hex

ef_$(1)_%: TARGET=ef_$(1)
ef_$(1)_%: OUTDIR=$(BUILD_DIR)/$$(TARGET)
ef_$(1)_%: BOARD_ROOT_DIR=$(ROOT_DIR)/flight/targets/$(1)

# rule for bootloader, must come first
$(eval $(call EF_RULE,$(1),$(2),$(3),$(4),fw_$(1)_tlfw bl_$(1)_bin))

# rule for without bootloader
$(eval $(call EF_RULE,$(1),$(2),$(3),$(4),fw_$(1)_tlfw))

.PHONY: ef_$(1)_clean
ef_$(1)_clean: TARGET=ef_$(1)
ef_$(1)_clean: OUTDIR=$(BUILD_DIR)/$$(TARGET)
ef_$(1)_clean:
	$(V0) @echo " CLEAN      $$@"
	$(V1) [ ! -d "$$(OUTDIR)" ] || $(RM) -r "$$(OUTDIR)"
endef

# $(1) = Canonical board name all in lower case (e.g. coptercontrol)
# $(2) = Friendly board name
# $(3) = Short board name
# $(4) = yes for bootloader, no for no bootloader
# $(5) = dependencies
define EF_RULE
ef_$(1)_%: $(5)
	$(V1) mkdir -p $$(OUTDIR)/dep
	$(V1) cd $(ROOT_DIR)/flight/targets/EntireFlash && \
		$$(MAKE) -r --no-print-directory \
		BOARD_NAME=$(1) \
		BOARD_SHORT_NAME=$(3) \
		BUILD_TYPE=ef \
		INCLUDE_BOOTLOADER=$(4) \
		TCHAIN_PREFIX="$(ARM_SDK_PREFIX)" \
		REMOVE_CMD="$(RM)" OOCD_EXE="$(OPENOCD)" \
		DFU_CMD="$(DFUUTIL_DIR)/bin/dfu-util" \
		\
		ROOT_DIR=$(ROOT_DIR) \
		BOARD_ROOT_DIR=$$(BOARD_ROOT_DIR) \
		BOARD_INFO_DIR=$$(BOARD_ROOT_DIR)/board-info \
		TARGET=$$(TARGET) \
		OUTDIR=$$(OUTDIR) \
		\
		$$*
endef

# $(1) = Canonical board name all in lower case (e.g. coptercontrol)
# $(2) = CPU arch (e.g. f1, f3, f4)
# $(3) = Short name for board (e.g CC)
define UP_TEMPLATE
.PHONY: up_$(1)
up_$(1): up_$(1)_tlfw

FW_FILES += $(BUILD_DIR)/up_$(1)/up_$(1).tlfw

up_$(1)_%: TARGET=up_$(1)
up_$(1)_%: OUTDIR=$(BUILD_DIR)/$$(TARGET)
up_$(1)_%: BOARD_ROOT_DIR=$(ROOT_DIR)/flight/targets/$(1)
up_$(1)_%: BLSRCDIR=$(ROOT_DIR)/flight/targets/bl
up_$(1)_%: BLCOMMONDIR=$$(BLSRCDIR)/common
up_$(1)_%: BLARCHDIR=$$(BLSRCDIR)/$(2)upgrader
up_$(1)_%: BLBOARDDIR=$$(BOARD_ROOT_DIR)/bl
up_$(1)_%:
	$(V1) mkdir -p $$(OUTDIR)/dep
	$(V1) cd $$(BLARCHDIR) && \
		$$(MAKE) -r --no-print-directory \
		BOARD_NAME=$(1) \
		BOARD_SHORT_NAME=$(3) \
		BUILD_TYPE=up \
		TCHAIN_PREFIX="$(ARM_SDK_PREFIX)" \
		REMOVE_CMD="$(RM)" OOCD_EXE="$(OPENOCD)" \
		\
		ROOT_DIR=$(ROOT_DIR) \
		BOARD_ROOT_DIR=$$(BOARD_ROOT_DIR) \
		BOARD_INFO_DIR=$$(BOARD_ROOT_DIR)/board-info \
		TARGET=$$(TARGET) \
		OUTDIR=$$(OUTDIR) \
		BLCOMMONDIR=$$(BLCOMMONDIR) \
		BLARCHDIR=$$(BLARCHDIR) \
		BLBOARDDIR=$$(BLBOARDDIR) \
		\
		$$*

# last 3 comments are temporary hackery until unified with #762

.PHONY: up_$(1)_clean
up_$(1)_clean: TARGET=up_$(1)
up_$(1)_clean: OUTDIR=$(BUILD_DIR)/$$(TARGET)
up_$(1)_clean:
	$(V0) @echo " CLEAN      $$@"
	$(V1) [ ! -d "$$(OUTDIR)" ] || $(RM) -r "$$(OUTDIR)"
endef

# When building any of the "all_*" targets, tell all sub makefiles to display
# additional details on each line of output to describe which build and target
# that each line applies to.
ifneq ($(strip $(filter all_%,$(MAKECMDGOALS))),)
export ENABLE_MSG_EXTRA := yes
endif
ifneq (,$(filter sim_%, $(MAKECMDGOALS)))
export ENABLE_MSG_EXTRA := yes
endif

# When building more than one goal in a single make invocation, also
# enable the extra context for each output line
ifneq ($(word 2,$(MAKECMDGOALS)),)
export ENABLE_MSG_EXTRA := yes
endif

UAVOLIB_SOFT_OUT_DIR = $(BUILD_DIR)/uavobjects_armsoftfp
UAVOLIB_HARD_OUT_DIR = $(BUILD_DIR)/uavobjects_armhardfp

uavobjects_armsoftfp: TARGET=uavobjects_armsoftfp
uavobjects_armsoftfp: OUTDIR=$(UAVOLIB_SOFT_OUT_DIR)

uavobjects_armhardfp: TARGET=uavobjects_armhardfp
uavobjects_armhardfp: OUTDIR=$(UAVOLIB_HARD_OUT_DIR)

uavobjects_%: uavobjects
	$(V1) mkdir -p $(OUTDIR)/dep
	$(V1) cd $(ROOT_DIR)/flight/uavobjectlib && \
		$(MAKE) -r --no-print-directory \
		TCHAIN_PREFIX="$(ARM_SDK_PREFIX)" \
		REMOVE_CMD="$(RM)" \
		\
		ROOT_DIR=$(ROOT_DIR) \
		TARGET=$(TARGET) \
		OUTDIR=$(OUTDIR) \
		\
		$@

.PHONY: uavobjects_armsoftfp_clean uavobjects_armhardfp_clean
uavobjects_armsoftfp_clean:
	$(V0) @echo " CLEAN      $@"
	$(V1) [ ! -d "$(UAVOLIB_SOFT_OUT_DIR)" ] || $(RM) -r "$(UAVOLIB_SOFT_OUT_DIR)"

uavobjects_armhardfp_clean:
	$(V0) @echo " CLEAN      $@"
	$(V1) [ ! -d "$(UAVOLIB_HARD_OUT_DIR)" ] || $(RM) -r "$(UAVOLIB_HARD_OUT_DIR)"

# $(1) = Canonical board name all in lower case (e.g. coptercontrol)
define BOARD_PHONY_TEMPLATE
.PHONY: all_$(1)
all_$(1): $$(filter fw_$(1), $$(FW_TARGETS))
all_$(1): $$(filter bl_$(1), $$(BL_TARGETS))
all_$(1): $$(filter bu_$(1), $$(BU_TARGETS))
all_$(1): $$(filter ef_$(1), $$(EF_TARGETS))
all_$(1): $$(filter up_$(1), $$(UP_TARGETS))

.PHONY: all_$(1)_clean
all_$(1)_clean: $$(addsuffix _clean, $$(filter fw_$(1), $$(FW_TARGETS)))
all_$(1)_clean: $$(addsuffix _clean, $$(filter bl_$(1), $$(BL_TARGETS)))
all_$(1)_clean: $$(addsuffix _clean, $$(filter bu_$(1), $$(BU_TARGETS)))
all_$(1)_clean: $$(addsuffix _clean, $$(filter ef_$(1), $$(EF_TARGETS)))
all_$(1)_clean: $$(addsuffix _clean, $$(filter up_$(1), $$(UP_TARGETS)))
endef

# Some boards don't use the bootloader
FW_BOARDS      := $(ALL_BOARDS)
NOBL_BOARDS    := $(strip $(foreach BOARD, $(ALL_BOARDS),$(if $(filter no,$($(BOARD)_bootloader)),$(BOARD))))
BL_BOARDS      := $(filter-out $(NOBL_BOARDS), $(ALL_BOARDS))
BU_BOARDS      := $(BL_BOARDS)
EF_BOARDS      := $(ALL_BOARDS)
UP_BOARDS      := cc3d

SIM_BOARDS := sim_posix

# Generate the targets for whatever boards are left in each list
FW_TARGETS := $(addprefix fw_, $(FW_BOARDS))
BL_TARGETS := $(addprefix bl_, $(BL_BOARDS))
BU_TARGETS := $(addprefix bu_, $(BU_BOARDS))
EF_TARGETS := $(addprefix ef_, $(EF_BOARDS))
UP_TARGETS := $(addprefix up_, $(UP_BOARDS))

.PHONY: all_fw all_fw_clean
all_fw:        $(addsuffix _tlfw,  $(FW_TARGETS))
all_fw_clean:  $(addsuffix _clean, $(FW_TARGETS)) uavobjects_armsoftfp_clean uavobjects_armhardfp_clean

.PHONY: all_bl all_bl_clean
all_bl:        $(addsuffix _bin,   $(BL_TARGETS))
all_bl_clean:  $(addsuffix _clean, $(BL_TARGETS))

.PHONY: all_bu all_bu_clean
all_bu:        $(addsuffix _tlfw,  $(BU_TARGETS))
all_bu_clean:  $(addsuffix _clean, $(BU_TARGETS))

.PHONY: all_ef all_ef_clean
all_ef:        $(EF_TARGETS)
all_ef_clean:  $(addsuffix _clean, $(EF_TARGETS))

.PHONY: all_up all_up_clean
all_up:        $(UP_TARGETS)
all_up_clean:  $(addsuffix _clean, $(UP_TARGETS))

.PHONY: all_sim all_sim_clean
all_sim: $(SIM_BOARDS)
all_sim_clean: $(addsuffix _clean, $(SIM_BOARDS))

.PHONY: all_flight all_flight_clean
all_flight:       all_fw all_bl all_bu all_ef all_up all_sim
all_flight_clean: all_fw_clean all_bl_clean all_bu_clean all_ef_clean all_sim_clean

# Expand the groups of targets for each board
$(foreach board, $(ALL_BOARDS), $(eval $(call BOARD_PHONY_TEMPLATE,$(board))))

# Expand the bootloader updater rules
$(foreach board, $(BU_BOARDS), $(eval $(call BU_TEMPLATE,$(board),$($(board)_cpuarch),$($(board)_short))))

# Expand the firmware rules
$(foreach board, $(FW_BOARDS), $(eval $(call FW_TEMPLATE,$(board),$($(board)_friendly),$($(board)_short))))

# Expand the bootloader rules
$(foreach board, $(BL_BOARDS), $(eval $(call BL_TEMPLATE,$(board),$($(board)_cpuarch),$($(board)_short))))

# Expand the entire-flash rules
$(foreach board, $(EF_BOARDS), $(eval $(call EF_TEMPLATE,$(board),$($(board)_friendly),$($(board)_short),$($(board)_bootloader))))

# Expand the upgrader rules
$(foreach board, $(UP_BOARDS), $(eval $(call UP_TEMPLATE,$(board),$($(board)_cpuarch),$($(board)_short))))

# Expand the available simulator rules
$(eval $(call SIM_TEMPLATE,simulation,Simulation,'sim ',posix,elf))

##############################
#
# Unit Tests
#
##############################

ALL_UNITTESTS := logfs misc_math coordinate_conversions error_correcting dsm timeutils circqueue
ALL_PYTHON_UNITTESTS := python_ut_test

UT_OUT_DIR := $(BUILD_DIR)/unit_tests

$(UT_OUT_DIR):
	$(V1) mkdir -p $@

.PHONY: all_ut
all_ut: $(addsuffix _elf, $(addprefix ut_, $(ALL_UNITTESTS))) $(ALL_PYTHON_UNITTESTS)

.PHONY: all_ut_xml
all_ut_xml: $(addsuffix _xml, $(addprefix ut_, $(ALL_UNITTESTS)))

.PHONY: all_ut_run
all_ut_run: $(addsuffix _run, $(addprefix ut_, $(ALL_UNITTESTS))) $(ALL_PYTHON_UNITTESTS)

.PHONY: all_ut_gcov
all_ut_gcov: | $(addsuffix _gcov, $(addprefix ut_, $(ALL_UNITTESTS)))

.PHONY: all_ut_clean
all_ut_clean:
	$(V0) @echo " CLEAN      $@"
	$(V1) [ ! -d "$(UT_OUT_DIR)" ] || $(RM) -r "$(UT_OUT_DIR)"

# $(1) = Unit test name
define UT_TEMPLATE
.PHONY: ut_$(1) ut_$(1)_run
ut_$(1): ut_$(1)_run
ut_$(1)_gcov: | ut_$(1)_xml

ut_$(1)_%: TARGET=$(1)
ut_$(1)_%: OUTDIR=$(UT_OUT_DIR)/$$(TARGET)
ut_$(1)_%: UT_ROOT_DIR=$(ROOT_DIR)/flight/tests/$(1)
ut_$(1)_%: $$(UT_OUT_DIR)
	$(V1) mkdir -p $(UT_OUT_DIR)/$(1)
	$(V1) cd $$(UT_ROOT_DIR) && \
		$$(MAKE) -r --no-print-directory \
		BUILD_TYPE=ut \
		BOARD_SHORT_NAME=$(1) \
		TCHAIN_PREFIX="" \
		REMOVE_CMD="$(RM)" \
		\
		ROOT_DIR=$(ROOT_DIR) \
		BOARD_ROOT_DIR=$$(BOARD_ROOT_DIR) \
		BOARD_INFO_DIR=$$(BOARD_ROOT_DIR)/board-info \
		TARGET=$$(TARGET) \
		OUTDIR=$$(OUTDIR) \
		\
		GTEST_DIR=$(GTEST_DIR) \
		\
		$$*

.PHONY: ut_$(1)_clean
ut_$(1)_clean: TARGET=$(1)
ut_$(1)_clean: OUTDIR=$(UT_OUT_DIR)/$$(TARGET)
ut_$(1)_clean:
	$(V0) @echo " CLEAN      $(1)"
	$(V1) [ ! -d "$$(OUTDIR)" ] || $(RM) -r "$$(OUTDIR)"
endef

# Expand the unittest rules
$(foreach ut, $(ALL_UNITTESTS), $(eval $(call UT_TEMPLATE,$(ut))))

.PHONY: python_ut_test
python_ut_test:
	$(V0) @echo "  PYTHON_UT test.py"
	$(V1) $(PYTHON) python/test.py

.PHONY: python_ut_ins
python_ut_ins:
	$(V0) @echo "  PYTHON_UT ins/test.py"
	$(V1) ( cd python/ins && \
	  $(PYTHON) setup.py build_ext --inplace && \
	  $(PYTHON) test.py \
	)

# Disable parallel make when the all_ut_run target is requested otherwise the TAP
# output is interleaved with the rest of the make output.
ifneq ($(strip $(filter all_ut_run,$(MAKECMDGOALS))),)
.NOTPARALLEL:
$(info *NOTE*     Parallel make disabled by all_ut_run target so we have sane console output)
endif

export FW_FILES := $(FW_FILES)
##############################
#
# Packaging components
#
##############################
PACKAGE_TARGETS = package_installer package_ground package_flight package_all
PACKAGE_TARGETS += package_ground_compress package_all_compress
.PHONY: $(PACKAGE_TARGETS)
$(PACKAGE_TARGETS): 
	$(V1) cd package && $(MAKE) --no-print-directory $@

package_flight: all_flight

##############################
#
# uncrustify 
#
##############################

ifneq ($(strip $(filter uncrustify_flight,$(MAKECMDGOALS))),)
  ifeq ($(FILE),)
    $(error pass files to uncrustify by adding FILE=<file> to the make command line)
  endif
endif

.PHONY: uncrustify_flight
uncrustify_flight: UNCRUSTIFY_OPTIONS := -c make/uncrustify.cfg --replace
uncrustify_flight:
	$(V1) $(UNCRUSTIFY) $(UNCRUSTIFY_OPTIONS) $(FILE)

##############################
#
# Doxygen Documentation
#
##############################

DOCS_TARGETS := flight ground

DOCS_BUILD_TARGETS := $(addprefix docs_, $(DOCS_TARGETS))
DOCS_CLEAN_TARGETS := $(addsuffix _clean, $(DOCS_BUILD_TARGETS))

.PHONY: docs docs_clean $(DOCS_BUILD_TARGETS) $(DOCS_CLEAN_TARGETS)

docs: $(DOCS_BUILD_TARGETS)

docs_clean: $(DOCS_CLEAN_TARGETS)

$(DOCS_BUILD_TARGETS): docs_%: $(BUILD_DIR) uavobjects
	$(V0) @echo "DOXYGEN     $*"
	$(V1) mkdir -p $(BUILD_DIR)/docs/$*
	$(V1) doxygen  $(DOXYGENDIR)/$*_doxygen.cfg

$(DOCS_CLEAN_TARGETS): docs_%_clean:
	$(V0) @echo " CLEAN      $(call toprel,$(BUILD_DIR)/docs/$*)"
	$(V1) [ ! -d "$(BUILD_DIR)/docs/$*" ] || $(RM) -r "$(BUILD_DIR)/docs/$*"
