# Any copyright is dedicated to the Public Domain.
# http://creativecommons.org/publicdomain/zero/1.0/
# Written by Nils Maier

# This make file will:
#  - Download a set of dependencies and verify the known-good hashes.
#  - Build static libraries of aria2 dependencies.
#  - Create a statically linked, aria2 release.
#    - The build will have all major features enabled, and will use
#      AppleTLS and GMP.
#  - Create a corresponding .tar.bz containing the binaries:
#  - Create a corresponding .pkg installer.
#  - Create a corresponding .dmg image containing said installer.
#
# This Makefile will also run all `make check` targets.
#
# The dependencies currently build are:
#  - zlib (compression, in particular web compression)
#  - c-ares (asynchronous DNS resolver)
#  - expat (XML parser, for metalinks)
#  - gmp (multi-precision arithmetric library, for DHKeyExchange, BitTorrent)
#  - sqlite3 (self-contained SQL database, for Firefox3 cookie reading)
#  - cppunit (unit tests for C++, framework in use by aria2 `make check`)
#
#
# To use this Makefile, do something along the lines of
#  - $ mkdir build-release
#  - $ cd build-release
#  - $ virtualenv .
#  - $ . bin/activate
#  - $ pip install sphinx-build
#  - $ ln -s ../makerelease-os.mk Makefile
#  - $ make
#
# If you haven't checkout out a release tag, you need to specify NON_RELEASE.
# $ export NON_RELEASE=1
# to generate a dist with git commit
# $ export NON_RELEASE=force
# to force this script to behave like it was on a tag.
#
# Note: This Makefile expects to be called from a git clone of aria2.
#
# Note: In theory, everything can be build in parallel, however the sub-makes
# will be called with an appropriate -j flag. Building the `deps` target in
# parallel before a general make might be beneficial, as the dependencies
# usually bottle-neck on the configure steps.
#
# Note: Of course, you need to have XCode with the command line tools
# installed for this to work, aka. a working compiler...
#
# Note: We're locally building the dependencies here, static libraries only.
# This is required, because when using brew or MacPorts, which also provide
# dynamic libraries, the linker will pick up the dynamic versions, always,
# with no way to instruct the linker otherwise.
# If you're building aria2 just for yourself and your system, using brewed
# libraries is fine as well.
#
# Note: This Makefile is riddled with mac-isms. It will not work on *nix.
#
# Note: The convoluted way to create separate arch builds and later merge them
# with lipo is because of two things:
#  1) Avoid patching c-ares, which hardcodes some sizes in its headers.
#
# Note: This Makefile uses resources from osx-package when creating the
# *.pkg and *.dmg targets

SHELL := bash

# A bit awkward, but OSX doesn't have a proper `readlink -f`.
SRCDIR := $(shell dirname $(lastword $(shell stat -f "%N %Y" $(lastword $(MAKEFILE_LIST)))))

# Same as in script-helper, but a bit easier on the eye (but more error prone)
# and Makefile compatible
BASE_VERSION = def
VERSION := $(BASE_VERSION)

# Set up compiler.
ARCH = x86_64
CC = cc
export CC
CXX = c++ -stdlib=libc++
export CXX

# Set up compiler/linker flags.
PLATFORMFLAGS ?= -mmacosx-version-min=10.10
OPTFLAGS ?= -Os
CFLAGS ?= $(PLATFORMFLAGS) $(OPTFLAGS)
export CFLAGS
CXXFLAGS ?= $(PLATFORMFLAGS) $(OPTFLAGS)
export CXXFLAGS
LDFLAGS ?= -Wl,-dead_strip
export LDFLAGS

LTO_FLAGS = -flto -ffunction-sections -fdata-sections


# ARCHLIBS that can be template build
ARCHLIBS = expat cares sqlite gmp libgpgerror libgcrypt libssh2
# NONARCHLIBS that cannot be template build
NONARCHLIBS = zlib


# Aria2 setup
ARIA2 := aria2-$(VERSION)
ARIA2_PREFIX := $(PWD)/$(ARIA2)
ARIA2_CONFFLAGS = \
        --enable-static \
        --disable-shared \
        --disable-metalink \
        --enable-bittorrent \
        --disable-nls \
        --with-appletls \
        --with-libz=/usr/local/opt/zlib \
		--with-gmp=/usr/local/opt/gmp \
		--with-libgcrypt=/usr/local/opt/libgcrypt \
		--with-libssh2=/usr/local/opt/libssh2 \
		--with-sqlite3=/usr/local/opt/sqlite \
		--with-expat=/usr/local/opt/expat \
		--with-libcares=/usr/local/opt/c-ares \
        --without-libuv \
        --without-gnutls \
        --without-openssl \
        --without-libnettle \
        --without-libxml2 \
		CFLAGS="-I/usr/local/include" \
  		LDFLAGS="-L/usr/local/lib -static" \
        ARIA2_STATIC=yes

# Detect number of CPUs to be used with make -j
CPUS = $(shell sysctl hw.ncpu | cut -d" " -f2)

# default target
all::

# Using (NON)ARCH_template kinda stinks, but real multi-target pattern rules
# only exist in feverish dreams.
define NONARCH_template
$(1).build: $(1).$(ARCH).build

deps:: $(1).build

endef

$(foreach lib,$(NONARCHLIBS),$(eval $(call NONARCH_template,$(lib))))

define ARCH_template
.PRECIOUS: $(1).%.build
$(1).%.build: $(1).stamp
	$$(eval DEST := $$(basename $$@))
	$$(eval ARCH := $$(subst .,,$$(suffix $$(DEST))))
	mkdir -p $$(DEST)
	( cd $$(DEST) && ../$(1)/configure \
		--enable-static --disable-shared \
		--prefix=$(PWD)/arch \
		$$($(1)_confflags) \
		CFLAGS="$$($(1)_cflags) -arch $$(ARCH)" \
		CXXFLAGS="$$($(1)_cxxflags) -arch $$(ARCH) -std=c++11" \
		LDFLAGS="$(LDFLAGS) $$($(1)_ldflags)" \
		PKG_CONFIG_PATH=$$(PWD)/arch/lib/pkgconfig \
		)
	$$(MAKE) -C $$(DEST) -sj$(CPUS)
	if test -z '$$($(1)_nocheck)'; then $$(MAKE) -C $$(DEST) -sj$(CPUS) check; fi
	$$(MAKE) -C $$(DEST) -s install
	touch $$@

$(1).build: $(1).$(ARCH).build

deps:: $(1).build

endef

$(foreach lib,$(ARCHLIBS),$(eval $(call ARCH_template,$(lib))))

.PRECIOUS: aria2.%.build
aria2.%.build:
	$(eval DEST := $$(basename $$@))
	$(eval ARCH := $$(subst .,,$$(suffix $$(DEST))))
	mkdir -p $(DEST)
	( cd $(DEST) && ../$(SRCDIR)/configure \
		--prefix=$(ARIA2_PREFIX) \
		--bindir=$(PWD)/$(DEST) \
		--sysconfdir=/etc \
		$(ARIA2_CONFFLAGS) \
		CFLAGS="$(CFLAGS) $(LTO_FLAGS) -arch $(ARCH) -I$(PWD)/arch/include" \
		CXXFLAGS="$(CXXFLAGS) $(LTO_FLAGS) -arch $(ARCH) -I$(PWD)/arch/include" \
		LDFLAGS="$(LDFLAGS) $(CXXFLAGS) $(LTO_FLAGS) -L$(PWD)/arch/lib" \
		PKG_CONFIG_PATH=$(PWD)/arch/lib/pkgconfig \
		)
	$(MAKE) -C $(DEST) -sj$(CPUS)
	# $(MAKE) -C $(DEST) -sj$(CPUS) check
	# Check that the resulting executable is Position-independent (PIE)
	otool -hv $(DEST)/src/aria2c | grep -q PIE
	$(MAKE) -C $(DEST) -sj$(CPUS) install-strip
	touch $@

aria2.build: aria2.$(ARCH).build
	mkdir -p $(ARIA2_PREFIX)/bin
	cp -f aria2.$(ARCH)/aria2c $(ARIA2_PREFIX)/bin/aria2c
	arch -64 $(ARIA2_PREFIX)/bin/aria2c -v
	touch $@

all:: aria2.build

clean:
	rm -rf *aria2*

.PHONY: all multi clean
