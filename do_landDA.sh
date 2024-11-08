#!/bin/bash -le
# script to run the land DA. Currently only option is the snow LETKFOI.
#
# 1. stage the restarts. 
# 2. stage and process obs. 
#    note: IMS obs prep currently requires model background, then conversion to IODA format.
# 3. create the JEDI yamls.
# 4. create pseudo ensemble (LETKF-OI).
# 5. run JEDI.
# 6. add increment file to restarts (and adjust any necessary dependent variables).
# 7. clean up.

# Clara Draper, Oct 2021.
# Aug 2020, generalized for all DA types.

#########################################
# source namelist and setup directories
#########################################

if [[ $# -gt 0 ]]; then 
    config_file=$1
else
    echo "do_landDA.sh: no config file specified, exting" 
    exit 1
fi

echo "reading DA settings from $config_file"

GFSv17=${GFSv17:-"NO"}

source $config_file

source ${LANDDADIR}/env_GDASApp

LOGDIR=${OUTDIR}/DA/logs/
OBSDIR=${OBSDIR:-"/scratch2/NCEPDEV/land/data/DA/"}

# set executable directories

export JEDI_EXECDIR=${JEDI_EXECDIR:-"${GDASApp_root}/build/bin/"}

# create local copy of JEDI_STATICDIR, so can over-ride default files 
# (March 2024, using own fieldMetaData override file)
JEDI_STATICDIR=${LANDDADIR}/jedi/fv3-jedi/Data/

# option to use apply_incr and IMS_proc execs from GDASApp
UseGDASAppExec="NO"

if [[ $UseGDASAppExec == "YES" ]]; then 
    FIMS_EXECDIR=${LANDDADIR}/GDASApp/build/bin/
    INCR_EXECDIR=${LANDDADIR}/GDASApp/build/bin/
else
    FIMS_EXECDIR=${LANDDADIR}/IMS_proc/exec/bin/
    INCR_EXECDIR=${LANDDADIR}/add_jedi_incr/exec/bin/
fi

# storage settings 

SAVE_IMS=${SAVE_IMS:-"NO"} # "YES" to save processed IMS IODA file
SAVE_INCR=${SAVE_INCR:-"NO"} # "YES" to save increment (add others?) JEDI output
SAVE_ANL=${SAVE_ANL:-"NO"} # "YES" to save JEDI Analysis outputs
SAVE_HOFX=${SAVE_HOFX:-"NO"} # "YES" to save hofx
SAVE_TILE=${SAVE_TILE:-"NO"} # "YES" to save background in tile space
KEEPJEDIDIR=${KEEPJEDIDIR:-"NO"} # delete DA workdir 

echo 'THISDATE in land DA, '$THISDATE

############################################################################################

# create output directories.
# we keep increment, hofx, and restart/forecast separate 
# TODO: review this later--some dirs may not be necessary
if [[ ! -e ${OUTDIR}/DA ]]; then
    mkdir -p ${OUTDIR}/DA
    mkdir ${OUTDIR}/DA/IMSproc
    mkdir ${OUTDIR}/DA/jedi_incr
    mkdir ${OUTDIR}/DA/logs
    mkdir ${OUTDIR}/DA/hofx
    mkdir ${OUTDIR}/DA/restarts    
    if [[ "$ensemble_size" -gt 1  ]]; then 
        mem_ens="mem000"
        mkdir ${OUTDIR}/DA/jedi_incr/${mem_ens} 
        mkdir ${OUTDIR}/DA/hofx/${mem_ens}           
        mkdir ${OUTDIR}/DA/restarts/${mem_ens}             
        for ie in $(seq $ensemble_size)     
        do
            mem_ens="mem`printf %03i $ie`"
            mkdir ${OUTDIR}/DA/jedi_incr/${mem_ens} 
            mkdir ${OUTDIR}/DA/hofx/${mem_ens}           
            mkdir ${OUTDIR}/DA/restarts/${mem_ens}                   
        done    
    fi     
fi 

if [[ ! -e $JEDIWORKDIR ]]; then 
    mkdir $JEDIWORKDIR      # ${WORKDIR}/jedi/  
    mkdir ${JEDIWORKDIR}/restarts 
    if [[ "$ensemble_size" -gt 1  ]]; then 
        mem_ens="mem000"
        mkdir $JEDIWORKDIR/restarts/${mem_ens}    
        for ie in $(seq $ensemble_size)
        do
            mem_ens="mem`printf %03i $ie`"
            mkdir $JEDIWORKDIR/restarts/${mem_ens}    
        done   
    fi 
    ln -s ${TPATH}/${TSTUB}* ${JEDIWORKDIR}
    ln -s ${TPATH}/${TSTUB}* ${JEDIWORKDIR}/restarts/ # to-do. change to only need one copy.
    ln -s ${OUTDIR} ${JEDIWORKDIR}/output
fi

cd $JEDIWORKDIR 

################################################
# 1. FORMAT DATE STRINGS AND STAGE RESTARTS
################################################

INCDATE=${LANDDADIR}/incdate.sh

YYYY=`echo $THISDATE | cut -c1-4`
MM=`echo $THISDATE | cut -c5-6`
DD=`echo $THISDATE | cut -c7-8`
HH=`echo $THISDATE | cut -c9-10`

PREVDATE=`${INCDATE} $THISDATE -$WINLEN`

YYYP=`echo $PREVDATE | cut -c1-4`
MP=`echo $PREVDATE | cut -c5-6`
DP=`echo $PREVDATE | cut -c7-8`
HP=`echo $PREVDATE | cut -c9-10`

FILEDATE=${YYYY}${MM}${DD}.${HH}0000

RSTRDIR=${WORKDIR}

if  [[ $SAVE_TILE == "YES" ]]; then   
    for ie in $(seq $ensemble_size)
    do
        if [[ "$ensemble_size" -eq 1  ]]; then 
            mem_ens="mem000"   
        else
            mem_ens="mem`printf %03i $ie`"     
        fi
        for tile in 1 2 3 4 5 6 
        do 
        cp ${RSTRDIR}/${mem_ens}/${FILEDATE}.sfc_data.tile${tile}.nc  ${RSTRDIR}/${mem_ens}/${FILEDATE}.sfc_data_back.tile${tile}.nc
        done    
    done  
fi 

#stage restarts for applying JEDI update (files will get directly updated)

cres_file=${JEDIWORKDIR}/restarts/${FILEDATE}.coupler.res
if [[ -e  ${RSTRDIR}/mem000/${FILEDATE}.coupler.res ]]; then 
    cp ${RSTRDIR}/${FILEDATE}.coupler.res $cres_file
else #  if not present, need to create coupler.res for JEDI 
    cp ${LANDDADIR}/template.coupler.res $cres_file

    sed -i -e "s/XXYYYY/${YYYY}/g" $cres_file
    sed -i -e "s/XXMM/${MM}/g" $cres_file
    sed -i -e "s/XXDD/${DD}/g" $cres_file
    sed -i -e "s/XXHH/${HH}/g" $cres_file

    sed -i -e "s/XXYYYP/${YYYP}/g" $cres_file
    sed -i -e "s/XXMP/${MP}/g" $cres_file
    sed -i -e "s/XXDP/${DP}/g" $cres_file
    sed -i -e "s/XXHP/${HP}/g" $cres_file

fi 
if [[ "$ensemble_size" -eq 1  ]]; then
    mem_ens="mem000"
    for tile in 1 2 3 4 5 6 
    do
        ln -fs ${RSTRDIR}/${mem_ens}/${FILEDATE}.sfc_data.tile${tile}.nc ${JEDIWORKDIR}/restarts/${FILEDATE}.sfc_data.tile${tile}.nc
    done
else    
    for ie in $(seq $ensemble_size)
    do
        mem_ens="mem`printf %03i $ie`"
        for tile in 1 2 3 4 5 6
        do
        ln -fs ${RSTRDIR}/${mem_ens}/${FILEDATE}.sfc_data.tile${tile}.nc ${JEDIWORKDIR}/restarts/${mem_ens}/${FILEDATE}.sfc_data.tile${tile}.nc
        done
        cp ${cres_file} ${JEDIWORKDIR}/restarts/${mem_ens}/${FILEDATE}.coupler.res
    done
fi

################################################
# 2. PREPARE OBS FILES
################################################

for ii in "${!OBS_TYPES[@]}"; # loop through requested obs
do 

  # get the obs file name 
  if [ ${OBS_TYPES[$ii]} == "GTS" ]; then
     obsfile=$OBSDIR/snow_depth/GTS/data_proc/${YYYY}${MM}/adpsfc_snow_${YYYY}${MM}${DD}${HH}.nc4
  elif [ ${OBS_TYPES[$ii]} == "GHCN" ]; then 
  # GHCN are time-stamped at 18. If assimilating at 00, need to use previous day's obs, so that 
  # obs are within DA window.
     obsfile=$OBSDIR/snow_depth/GHCN/data_proc/v3/${YYYP}/ghcn_snwd_ioda_${YYYP}${MP}${DP}.nc
  elif [ ${OBS_TYPES[$ii]} == "SYNTH" ]; then 
     obsfile=$OBSDIR/synthetic_noahmp/IODA.synthetic_gswp_obs.${YYYY}${MM}${DD}${HH}.nc
  elif [ ${OBS_TYPES[$ii]} == "SMAP" ]; then
     obsfile=$OBSDIR/soil_moisture/SMAP/data_proc/${YYYY}/smap_${YYYY}${MM}${DD}T${HH}00.nc
  elif [ ${OBS_TYPES[$ii]} == "IMS" ]; then 
     DOY=$(date -d "${YYYY}-${MM}-${DD}" +%j)
     echo DOY is ${DOY}

     if [[ $THISDATE -gt 2014120200 ]];  then
        ims_vsn=1.3
        imsformat=2 # nc
        imsres='4km'
        fsuf='nc'
        ascii=''
     elif [[ $THISDATE -gt 2004022400 ]]; then
        ims_vsn=1.2
        imsformat=2 # nc
        imsres='4km'
        fsuf='nc'
        ascii=''
     else
        ims_vsn=1.1
        imsformat=1 # asc
        imsres='24km'
        fsuf='asc'
        ascii='ascii'
     fi
    obsfile=${OBSDIR}/snow_ice_cover/IMS/${YYYY}/ims${YYYY}${DOY}_${imsres}_v${ims_vsn}.${fsuf}
  else
     echo "do_landDA: Unknown obs type requested ${OBS_TYPES[$ii]}, exiting" 
     exit 1 
  fi

  # check obs are available
  if [[ -e $obsfile ]]; then
    echo "do_landDA: ${OBS_TYPES[$ii]} observations found: $obsfile"
    if [ ${OBS_TYPES[$ii]} != "IMS" ]; then 
       ln -fs $obsfile  ${OBS_TYPES[$ii]}_${YYYY}${MM}${DD}${HH}.nc
    fi 
  else
    echo "${OBS_TYPES[$ii]} observations not found: $obsfile"
    JEDI_TYPES[$ii]="SKIP"
  fi

  # pre-process and call IODA converter for IMS obs.
  if [[ ${OBS_TYPES[$ii]} == "IMS"  && ${JEDI_TYPES[$ii]} != "SKIP" ]]; then

    if [[ -e fims.nml ]]; then
        rm -rf fims.nml 
    fi
cat >> fims.nml << EOF
 &fIMS_nml
  idim=$RES, jdim=$RES,
  otype=${TSTUB},
  jdate=${YYYY}${DOY},
  yyyymmddhh=${YYYY}${MM}${DD}.${HH},
  fcst_path="./restarts/",
  imsformat=${imsformat},
  imsversion=${ims_vsn},
  imsres=${imsres},
  IMS_OBS_PATH="${OBSDIR}/snow_ice_cover/IMS/${YYYY}/",
  IMS_IND_PATH="${OBSDIR}/snow_ice_cover/IMS/index_files/",
  /
EOF
    echo 'do_landDA: calling fIMS'

    ${FIMS_EXECDIR}/calcfIMS.exe
    if [[ $? != 0 ]]; then
        echo "fIMS failed"
        exit 10
    fi

    IMS_IODA=imsfv3_scf2iodaTemp.py # 2024-07-12 temporary until GDASApp ioda converter updated.
    cp ${LANDDADIR}/jedi/ioda/${IMS_IODA} $JEDIWORKDIR

    echo 'do_landDA: calling ioda converter' 

    python ${IMS_IODA} -i IMSscf.${YYYY}${MM}${DD}.${TSTUB}.nc -o ${JEDIWORKDIR}ioda.IMSscf.${YYYY}${MM}${DD}.${TSTUB}.nc 
    if [[ $? != 0 ]]; then
        echo "IMS IODA converter failed"
        exit 10
    fi
  fi #IMS

done # OBS_TYPES

################################################
# 3. DETERMINE REQUESTED JEDI TYPE, CONSTRUCT YAMLS
################################################

export do_DA="NO"
do_HOFX="NO"

for ii in "${!OBS_TYPES[@]}"; # loop through requested obs
do
   if [ ${JEDI_TYPES[$ii]} == "DA" ]; then 
         export do_DA="YES" 
   elif [ ${JEDI_TYPES[$ii]} == "HOFX" ]; then
         export do_HOFX="YES" 
   elif [ ${JEDI_TYPES[$ii]} != "SKIP" ]; then
         echo "do_landDA:Unknown obs action ${JEDI_TYPES[$ii]}, exiting" 
         exit 1
   fi
done

if [[ $do_DA == "NO" && $do_HOFX == "NO" ]]; then 
        echo "do_landDA:No obs found, not calling JEDI" 
        exit 0 
fi

# if yaml is specified by user, use that. Otherwise, build the yaml
if [[ $do_DA == "YES" ]]; then 

   if [[ $YAML_DA == "construct" ]];then  # construct the yaml

      cp ${LANDDADIR}/jedi/fv3-jedi/yaml_files/${DAalg}/${analVar}.yaml ${JEDIWORKDIR}/jedi_DA.yaml

      for ii in "${!OBS_TYPES[@]}";
      do 
        if [ ${JEDI_TYPES[$ii]} == "DA" ]; then
        cat ${LANDDADIR}/jedi/fv3-jedi/yaml_files/${DAalg}/${OBS_TYPES[$ii]}.yaml >> jedi_DA.yaml
        fi 
      done

   else # use specified yaml 
      echo "Using user specified YAML: ${YAML_DA}"
      cp ${LANDDADIR}/jedi/fv3-jedi/yaml_files/${YAML_DA} ${JEDIWORKDIR}/jedi_DA.yaml
   fi

   sed -i -e "s/XXYYYY/${YYYY}/g" jedi_DA.yaml
   sed -i -e "s/XXMM/${MM}/g" jedi_DA.yaml
   sed -i -e "s/XXDD/${DD}/g" jedi_DA.yaml
   sed -i -e "s/XXHH/${HH}/g" jedi_DA.yaml

   sed -i -e "s/XXYYYP/${YYYP}/g" jedi_DA.yaml
   sed -i -e "s/XXMP/${MP}/g" jedi_DA.yaml
   sed -i -e "s/XXDP/${DP}/g" jedi_DA.yaml
   sed -i -e "s/XXHP/${HP}/g" jedi_DA.yaml

   sed -i -e "s/XXTSTUB/${TSTUB}/g" jedi_DA.yaml
   sed -i -e "s#XXTPATH#${TPATH}#g" jedi_DA.yaml
   sed -i -e "s/XXRES/${RES}/g" jedi_DA.yaml
   sed -i -e "s/XXORES/${ORES}/g" jedi_DA.yaml
   RESP1=$((RES+1))
   sed -i -e "s/XXREP/${RESP1}/g" jedi_DA.yaml

   sed -i -e "s/XXHOFX/false/g" jedi_DA.yaml  # do DA
   
   sed -i -e "s/XXDT/${WINLEN}/g" jedi_DA.yaml  #  DA window lenth
   sed -i -e "s/XXNTIL/${num_tiles}/g" jedi_DA.yaml  # Number of tiles
   sed -i -e "s/XXNPZ/${NPZ}/g" jedi_DA.yaml  # vertical layers
   sed -i -e "s/XXLX/${LayX}/g" jedi_DA.yaml  # Layout
   sed -i -e "s/XXLY/${LayY}/g" jedi_DA.yaml
   sed -i -e "s/XXIOLX/${IOLayX}/g" jedi_DA.yaml #IO Layout
   sed -i -e "s/XXIOLY/${IOLayY}/g" jedi_DA.yaml

fi

if [[ $do_HOFX == "YES" ]]; then 

   if [[ $YAML_HOFX == "construct" ]];then  # construct the yaml

      cp ${LANDDADIR}/jedi/fv3-jedi/yaml_files/${DAalg}/${analVar}.yaml ${JEDIWORKDIR}/jedi_hofx.yaml

      for ii in "${!OBS_TYPES[@]}";
      do 
        if [ ${JEDI_TYPES[$ii]} == "HOFX" ]; then
        cat ${LANDDADIR}/jedi/fv3-jedi/yaml_files/${DAalg}/${OBS_TYPES[$ii]}.yaml >> jedi_hofx.yaml
        fi 
      done
   else # use specified yaml 
      echo "Using user specified YAML: ${YAML_HOFX}"
      cp ${LANDDADIR}/jedi/fv3-jedi/yaml_files/${YAML_HOFX} ${JEDIWORKDIR}/jedi_hofx.yaml
   fi

   sed -i -e "s/XXYYYY/${YYYY}/g" jedi_hofx.yaml
   sed -i -e "s/XXMM/${MM}/g" jedi_hofx.yaml
   sed -i -e "s/XXDD/${DD}/g" jedi_hofx.yaml
   sed -i -e "s/XXHH/${HH}/g" jedi_hofx.yaml

   sed -i -e "s/XXYYYP/${YYYP}/g" jedi_hofx.yaml
   sed -i -e "s/XXMP/${MP}/g" jedi_hofx.yaml
   sed -i -e "s/XXDP/${DP}/g" jedi_hofx.yaml
   sed -i -e "s/XXHP/${HP}/g" jedi_hofx.yaml

   sed -i -e "s#XXTPATH#${TPATH}#g" jedi_hofx.yaml
   sed -i -e "s/XXTSTUB/${TSTUB}/g" jedi_hofx.yaml
   sed -i -e "s/XXRES/${RES}/g" jedi_hofx.yaml
   sed -i -e "s/XXORES/${ORES}/g" jedi_DA.yaml
   RESP1=$((RES+1))
   sed -i -e "s/XXREP/${RESP1}/g" jedi_hofx.yaml
   
   sed -i -e "s/XXHOFX/true/g" jedi_hofx.yaml  # do only HOFX

   sed -i -e "s/XXDT/${WINLEN}/g" jedi_hofx.yaml  #  DA window lenth
   sed -i -e "s/XXNTIL/${num_tiles}/g" jedi_DA.yaml  # Number of tiles
   sed -i -e "s/XXNPZ/${NPZ}/g" jedi_hofx.yaml  # vertical layers
   sed -i -e "s/XXLX/${LayX}/g" jedi_DA.yaml  # Layout
   sed -i -e "s/XXLY/${LayY}/g" jedi_DA.yaml
   sed -i -e "s/XXIOLX/${IOLayX}/g" jedi_DA.yaml #IO Layout
   sed -i -e "s/XXIOLY/${IOLayY}/g" jedi_DA.yaml

fi

###############################################################
# 4. EDIT RUN SETTINGS and CREATE BACKGROUND ENSEMBLE (LETKFOI)
###############################################################

if [ $GFSv17 == "YES" ]; then
    SNOWDEPTHVAR="snodl"
    cp ${LANDDADIR}/jedi/fv3-jedi/yaml_files/gfs-land-v17.yaml ${JEDIWORKDIR}/gfs-land-v17.yaml
else
    SNOWDEPTHVAR="snwdph"
fi

JEDI_EXEC="fv3jedi_letkf.x"

if [[ ${DAalg} == '2DVar' ]]; then

    JEDI_EXEC="fv3jedi_var.x"

elif [[ ${DAalg} == 'letkfoi' ]]; then
#To-do: make this section generic (currently assumes snow)

    B=30  # back ground error std for LETKFOI

    # FOR LETKFOI, CREATE THE PSEUDO-ENSEMBLE
    for ens in pos neg
    do
        if [ -e $JEDIWORKDIR/mem_${ens} ]; then
                rm -r $JEDIWORKDIR/mem_${ens}
        fi
        mkdir $JEDIWORKDIR/mem_${ens}
        for tile in 1 2 3 4 5 6
        do
        cp ${JEDIWORKDIR}/restarts/${FILEDATE}.sfc_data.tile${tile}.nc  ${JEDIWORKDIR}/mem_${ens}/${FILEDATE}.sfc_data.tile${tile}.nc
        done
        cp ${JEDIWORKDIR}/restarts/${FILEDATE}.coupler.res ${JEDIWORKDIR}/mem_${ens}/${FILEDATE}.coupler.res
    done

    echo 'do_landDA LETKFOI: calling create ensemble'

    python ${LANDDADIR}/letkf_create_ens.py $FILEDATE $SNOWDEPTHVAR $B
    if [[ $? != 0 ]]; then
        echo "letkf create ensemble failed"
        exit 10
    fi

elif [[ ${DAalg} == 'letkfoi_smc' ]]; then
# To-do : combine this with the above

    cp ${LANDDADIR}/jedi/fv3-jedi/yaml_files/gfs-soilMoisture.yaml ${JEDIWORKDIR}/gfs-soilMoisture.yaml

elif [[ ${DAalg} == 'letkf' ]]; then

    if [[ $YAML_DA == "construct" ]];then

        cp ${LANDDADIR}/jedi/fv3-jedi/yaml_files/${DAalg}/bkg1mem.yaml ${JEDIWORKDIR}/bkg1mem.yaml
        sed -i -e "s/XXYYYY/${YYYY}/g" bkg1mem.yaml
        sed -i -e "s/XXMM/${MM}/g" bkg1mem.yaml
        sed -i -e "s/XXDD/${DD}/g" bkg1mem.yaml
        sed -i -e "s/XXHH/${HH}/g" bkg1mem.yaml
        for ie in $(seq $ensemble_size)
        do
            cp bkg1mem.yaml backgroundens.yaml
            mem_ens="mem`printf %03i $ie`"
            sed -i -e "s/XXMEM/${mem_ens}/g" backgroundens.yaml
            cat backgroundens.yaml >> jedi_DA.yaml
        done
    fi

    if [[ $YAML_HOFX == "construct" ]];then
        cp ${LANDDADIR}/jedi/fv3-jedi/yaml_files/${DAalg}/bkg1mem.yaml ${JEDIWORKDIR}/bkg1mem.yaml
        sed -i -e "s/XXYYYY/${YYYY}/g" bkg1mem.yaml
        sed -i -e "s/XXMM/${MM}/g" bkg1mem.yaml
        sed -i -e "s/XXDD/${DD}/g" bkg1mem.yaml
        sed -i -e "s/XXHH/${HH}/g" bkg1mem.yaml
        for ie in $(seq $ensemble_size)
        do
            cp bkg1mem.yaml backgroundens.yaml
            mem_ens="mem`printf %03i $ie`"
            sed -i -e "s/XXMEM/${mem_ens}/g" backgroundens.yaml
            cat backgroundens.yaml >> jedi_hofx.yaml
        done
    fi
fi

################################################
# 5. RUN JEDI
################################################

NPROC_JEDI=$SLURM_NTASKS

if [[ ! -e Data ]]; then
    ln -s $JEDI_STATICDIR Data 
fi

echo 'do_landDA: calling fv3-jedi' 

if [[ $do_DA == "YES" ]]; then
    time srun -n $NPROC_JEDI ${JEDI_EXECDIR}/${JEDI_EXEC} jedi_DA.yaml ${LOGDIR}/jedi_DA.log
    if [[ $? != 0 ]]; then
        echo "JEDI DA failed"
        exit 10
    fi
fi 
if [[ $do_HOFX == "YES" ]]; then  
    time srun -n $NPROC_JEDI ${JEDI_EXECDIR}/${JEDI_EXEC} jedi_hofx.yaml ${LOGDIR}/jedi_hofx.log
    if [[ $? != 0 ]]; then
        echo "JEDI hofx failed"
        exit 10
    fi
fi 

################################################
# 6. APPLY INCREMENT TO UFS RESTARTS 
################################################

if [[ $do_DA == "YES" ]]; then 

    if [[ "$ensemble_size" -gt 1  ]]; then 
        rst_path="./restarts/"
        inc_path="./output/DA/jedi_incr/"
    else
        for tile in 1 2 3 4 5 6 
        do
            ln -fs ${JEDIWORKDIR}/restarts/${FILEDATE}.sfc_data.tile${tile}.nc ${JEDIWORKDIR}/${FILEDATE}.sfc_data.tile${tile}.nc
        done
        rst_path="./"
        inc_path="./"
    fi

    frac_grid=.false.
    if [[ $GFSv17 == "YES" ]]; then
        frac_grid=.true.
    fi

  if [[ $analVar == "snow" ]]; then
cat << EOF > apply_incr_nml
&noahmp_snow
 date_str=${YYYY}${MM}${DD}
 hour_str=$HH
 res=$RES
 frac_grid=$frac_grid
 orog_path="$TPATH"
 otype="$TSTUB"
 rst_path="$rst_path"
 inc_path="$inc_path"
 ntiles=$num_tiles
 ens_size=$ensemble_size
/
EOF

    echo 'do_landDA: calling apply snow increment'
 
    time srun '--export=ALL' -n $NPROC_JEDI ${INCR_EXECDIR}/apply_incr.exe ${LOGDIR}/apply_incr.log
    if [[ $? != 0 ]]; then
        echo "apply snow increment failed"
        exit 10
    fi
  fi
fi 

################################################
# 7. CLEAN UP
################################################

# keep IMS IODA file
# note we are forcing overwrite
#TODO check whether to keep or delete outdir/da/hofx rather than copying
# Also it might be better to do these copies above and work within ${JEDIWORKDIR}/output/DA/
if [ $SAVE_IMS == "YES"  ]; then
   if [[ -e ${JEDIWORKDIR}/ioda.IMSscf.${YYYY}${MM}${DD}.${TSTUB}.nc ]]; then
      mv -f ${JEDIWORKDIR}/ioda.IMSscf.${YYYY}${MM}${DD}.${TSTUB}.nc ${JEDIWORKDIR}/output/DA/IMSproc/
    #   yes |cp -u ${JEDIWORKDIR}/ioda.IMSscf.${YYYY}${MM}${DD}.${TSTUB}.nc ${OUTDIR}/DA/IMSproc/
   fi
fi 

# keep increments
if [ $SAVE_INCR == "YES" ] && [ $do_DA == "YES" ]; then
    if [[ "$ensemble_size" -eq 1  ]]; then 
        mv -f ${JEDIWORKDIR}/snowinc.${FILEDATE}.sfc_data.tile*.nc  ${JEDIWORKDIR}/output/DA/jedi_incr/    
        # yes |cp -u ${JEDIWORKDIR}/snowinc.${FILEDATE}.sfc_data.tile*.nc  ${OUTDIR}/DA/jedi_incr/       
    # else # This is already linked above
        # yes |cp -r -u ${JEDIWORKDIR}/output/DA/jedi_incr/*  ${OUTDIR}/DA/jedi_incr/           
    fi	
fi 

# keep analysis restarts (for LETKF)
if [ $SAVE_ANL == "YES" ] && [ $do_DA == "YES" ]; then
    if [[ "$ensemble_size" -eq 1  ]]; then
        yes |cp -u ${JEDIWORKDIR}/restarts/${FILEDATE}.sfc_data.tile*.nc  ${JEDIWORKDIR}/output/DA/restarts/
        # yes |cp -u ${JEDIWORKDIR}/restarts/${FILEDATE}.sfc_data.tile*.nc  ${OUTDIR}/DA/restarts/

    # else # This is already linked above
        # for ie in $(seq $ensemble_size)
        # do
        #     mem_ens="mem`printf %03i $ie`"
        #     yes |cp -u ${JEDIWORKDIR}/output/DA/restarts/${mem_ens}/${FILEDATE}.sfc_data.tile*.nc  ${OUTDIR}/DA/restarts/${mem_ens}
        # done
    fi
fi

# keep hofx
# if [[ $SAVE_HOFX == "YES" ]]; then
#     if [ $do_DA == "YES" ] || [ $do_HOFX == "YES" ]; then
#         # yes |cp -r -u ${JEDIWORKDIR}/output/DA/hofx/*  ${OUTDIR}/DA/hofx/
#     fi
# fi

# clean up 
if [[ $KEEPJEDIDIR == "NO" ]]; then
   rm -rf ${JEDIWORKDIR} 
fi
