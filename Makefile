# Requires Github CLI (gh) command to facilitate authenticated requests to the API
#
# Quick start:
#   Generate tile set:
#     export TILENAME=test # or na, afr, eur, ...
#     make clean
#     make ${TILENAME}_tile_list_chunks
#     make -j $(nproc --ignore=2)
#
#   Generate single tile:
#     make z_ao__single_+78+015.zip

# remove make builtin rules for more useful make -d 
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --no-builtin-variables

# @todo: make release in kubilus/autoortho-scenery, see ./bin/prepareAssetsElevationData
ELEV_RELEASE_JSON_ENDPOINT?=repos/jonaseberle/autoortho-scenery/releases/tags/elevation-v0.0.1
SPLITSIZE?=125
SHELL=/bin/bash
ZL?=16

TILENAME?=test

TILES:=$(addprefix z_$(TILENAME)_, $(shell ls $(TILENAME)_tile_list.* 2>/dev/null | awk -F. '{ print $$2 }') ) 
TILE_ZIPS=$(addsuffix .zip, $(TILES))

ZIPS=$(TILE_ZIPS)

# paranthesis to use in shell commands
# make chokes on () in shell commands
OP:=(
CP:=)

# Get the tiles listed in each list file
.SECONDEXPANSION:
TILE_FILES = $(addsuffix .dsf, $(addprefix Ortho4XP/Tiles/*/*/*/, $(basename $(shell cat $(TILENAME)_tile_list.$* 2>/dev/null ) ) ) )
TILE_FILES_ALL = $(addsuffix .dsf, $(addprefix Ortho4XP/Tiles/*/*/*/, $(basename $(shell cat $(TILENAME)_tile_list 2>/dev/null ) ) ) )

all: $(ZIPS)

# creates directories
%/:
	@mkdir -p $@

#
# Work on tile lists
#
z_$(TILENAME): $(TILENAME)_tile_list $${TILE_FILES_ALL}
	@echo "[$@]"
	@mkdir -p $@
	@cp -r Ortho4XP/Tiles/zOrtho4XP_*/'Earth nav data' $@/.
	@cp -r Ortho4XP/Tiles/zOrtho4XP_*/terrain $@/.
	@cp -r Ortho4XP/Tiles/zOrtho4XP_*/textures $@/

z_$(TILENAME)_%: $(TILENAME)_tile_list.% $${TILE_FILES}
	@echo "[$@]"
	
z_$(TILENAME)_%.zip.info: z_$(TILENAME)_%.zip
	@echo "[$@]"
	@echo "-----------------------------------"
	@echo "Post processing info:"
	@comm --total -3  <( unzip -l $(basename $@) *.dsf | awk -F/ '/.*\.dsf/ { print $$4 }' | sort ) <( cat $(TILENAME)_tile_list.$* | sort )
	@echo "-----------------------------------"
	@export EXPECTED=$$(cat $(TILENAME)_tile_list.$* | wc -l); \
		export ACTUAL=$$(unzip -l $(basename $@) *.dsf | grep dsf | wc -l); \
		echo "Expected tile len: $$EXPECTED"; \
		echo "Actual tile len: $$ACTUAL"; \
	[ $$EXPECTED -eq $$ACTUAL ]

#
# Ortho4XP setup
#

ortho4xp.diff:
	@echo "[$@]"
	cd Ortho4XP && git diff > ../ortho4xp.diff

Ortho4XP:
	@echo "[$@]"
	git clone --depth=1 https://github.com/oscarpilote/Ortho4XP.git
	cp extract_overlay.py $@/.
	cp Ortho4XP.cfg $@/.
	@mkdir $@/tmp
	@echo "Setting up symlinks in order to not care about Ortho4XP's expected directory structure in ./Elevation_data..."
	@mkdir -p $@/Elevation_data && cd $@/Elevation_data \
		&& bash -c 'for lat in {-9..9}; do for lon in {-18..18}; do ln -snfr ./ "./$$(printf "%+d0%+03d0" "$$lat" "$$lon")"; done; done'
	mkdir -p var/cache/ferranti_nonStandardNames/ \
		&& cd var/cache/ferranti_nonStandardNames/ \
		&& wget --continue http://viewfinderpanoramas.org/dem3/GL-North.zip \
		&& wget --continue http://viewfinderpanoramas.org/dem3/GL-West.zip \
		&& wget --continue http://viewfinderpanoramas.org/dem3/GL-East.zip \
		&& wget --continue http://viewfinderpanoramas.org/dem3/GL-South.zip \
		&& unzip -j -d ../../../Ortho4XP/Elevation_data -o '*.zip'

#
# Custom tile elevation
#

# generates the targets var/run/neighboursOfTile_%.elevation with surrounding tiles' elevations 
# as prerequisites (takes a little while, 360*180 rules):
var/run/Makefile.elevationRules: | $$(@D)/
	@echo "[$@]"
	@bin/genMakefileElevationRules > $@
include var/run/Makefile.elevationRules

var/run/tile_%.elevation: var/cache/elevation/elevation_%.zip Ortho4XP | $$(@D)/
	@# Unzips if file not empty, but fails on unzip error.
	@# Ignores the .zip if empty
	@if [ -s "var/cache/elevation/elevation_$*.zip" ]; then \
		printf "[$@] unzipping custom elevation: %s\n" \
			"$$(unzip -o -d Ortho4XP/Elevation_data/ var/cache/elevation/elevation_$*.zip | tr "\n" " | ")"; \
	else \
		echo "[$@] no custom elevation for this tile"; \
	fi
	@touch $@

var/run/elevationRelease.json: | $$(@D)/
	@echo "[$@]"
	@json="$$(gh api $(ELEV_RELEASE_JSON_ENDPOINT) --paginate)" \
		&& echo "$$json" > $@ \
		&& printf "[$@] got %s\n" "$$(jq -r '.assets[].name' $@ | tr --delete "elevation_" | tr --delete ".zip" | tr "\n" ",")"

var/cache/elevation/elevation_%.zip: var/run/elevationRelease.json | $$(@D)/
	@# Fails if we expect a file but download failed. 
	@# Creates an empty .zip file if there is no custom elevation.
	@url=$$(jq -r '.assets[] | select$(OP).name == "elevation_$*.zip"$(CP) .browser_download_url' \
			var/run/elevationRelease.json); \
		if [ -n "$$url" ]; then \
			echo "[$@] downloading custom elevation"; \
			wget --continue --quiet -O $@ "$$url" && touch $@; \
		else \
			echo "[$@] no custom elevation for this tile"; \
			touch $@; \
		fi

#
# Split tile list
#

#$(TILENAME)_tile_list.%: $(TILENAME)_tile_list_chunks

$(TILENAME)_tile_list_chunks: $(TILENAME)_tile_list
	@echo "[$@]"
	split $< -d -l $(SPLITSIZE) $<.

#
# Tile pack setup
#

Ortho4XP/Tiles/*/*/*/%.dsf: Ortho4XP var/run/neighboursOfTile_%.elevation
	@echo [$@]
	@mkdir -p Ortho4XP/Tiles/zOrtho4XP_$*
	@echo "Setup per tile config, if possible"
	@cp Ortho4XP_$*.cfg Ortho4XP/Tiles/zOrtho4XP_$*/. 2>/dev/null || true
	@echo "Available elevation data for this tile before Ortho4XP run (25M is HD 1\", 2.8M is 3\"):"
	@#ls Ortho4XP/Elevation_data/ -sh
	@hgtLat="$$(grep -Eo '^.{3}' <<< $* | tr "+" "N" | tr "-" "S")" \
		&& hgtLon="$$(grep -Eo '.{4}$$' <<< $* | tr "+" "E" | tr "-" "W")" \
		&& hgtFilePath=Ortho4XP/Elevation_data/"$$hgtLat$$hgtLon".hgt \
		&& ( [ -e "$$hgtFilePath" ] && ls -sh "$$hgtFilePath" || true )
	# this silences deprecation warnings in Ortho4XP for more concise output
	@set -e;\
	export COORDS=$$(echo $(@) | sed -e 's/.*\/\([-+][0-9]\+\)\([-+][0-9]\+\).dsf/\1 \2/g');\
	cd Ortho4XP \
		&& python3 Ortho4XP.py $$COORDS BI $(ZL) 2>&1 \
		|| ( \
			echo "ERROR DETECTED! Retry tile $@ with noroads config."; \
			cp $(CURDIR)/Ortho4XP_noroads.cfg $(CURDIR)/Ortho4XP/Tiles/zOrtho4XP_$*/Ortho4XP_$*.cfg \
			&& python3 Ortho4XP.py $$COORDS BI $(ZL) 2>&1 \
		);

var/run/z_ao__single_%: Ortho4XP/Tiles/*/*/*/%.dsf
	@echo "[$@]"
	@cp -r Ortho4XP/Tiles/zOrtho4XP_$*/ var/run/z_ao__single_$*

z_ao__single_%.zip: var/run/z_ao__single_%
	@echo "[$@]"
	@cd var/run/z_ao__single_$* && zip -r ../../../$@ .

.SECONDARY: $(TILE_FILES) 

# Static pattern rule for the zip files
$(ZIPS): z_%.zip: z_%
	@echo "[$@]"
	@mkdir -p $<
	@cp -r Ortho4XP/Tiles/zOrtho4XP_*/'Earth nav data' $</.
	@cp -r Ortho4XP/Tiles/zOrtho4XP_*/terrain $</.
	@cp -r Ortho4XP/Tiles/zOrtho4XP_*/textures $</.
	@zip -r $@ $<
	
%.sha256: %		
	@echo "[$@]"
	sha256sum $< > $@

clean:
	@echo "[$@]"
	-rm -rf Ortho4XP/Tiles/*
	-rm -rf var/run
	-rm -f $(ZIPS)
	-rm -rf z_$(TILENAME)*
	-rm -rf z_ao__single_*
	-rm -f $(TILENAME)_tile_list.*

distclean: clean
	@echo "[$@]"
	-rm -rf Ortho4XP
	-rm -rf var
	-rm -rf z_*
	-rm -f *_tile_list.*
