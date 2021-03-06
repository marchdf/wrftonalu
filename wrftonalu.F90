!------------------------------------------------------------------------------
!
! PROGRAM: wrftonalu
!
!> @author
!> Marc T. Henry de Frahan, National Renewable Energy Laboratory
!
!> @brief
!> Reads in WRF output files and outputs Nalu Exodus II boundary conditions
!
!> @date 01/12/2016 J. Michalakes and M. Churchfield
!> - Initial version from WRFTOOOF
! 
!------------------------------------------------------------------------------

PROGRAM wrftonalu
  USE module_constants
  USE module_dm
  USE module_ncderrcheck
  USE module_exodus
  IMPLICIT NONE

  !================================================================================
  !
  ! Initialize variables
  !
  !================================================================================

  ! domain specification variables
  INTEGER :: ids , ide , jds , jde , kds , kde
  INTEGER :: ims , ime , jms , jme , kms , kme ! some of this is unnecessary for serial
  INTEGER :: ips , ipe , jps , jpe , kps , kpe ! ditto
  ! variables for using netcdf
  INCLUDE 'netcdf.inc'
  INTEGER, PARAMETER :: MAXFILES = 20
  CHARACTER(LEN=255) :: flnm(MAXFILES),arg,vname,comstr
  CHARACTER(LEN=19) :: Times(100),tmpstr,secstr
  LOGICAL ic, ic_is_written, ctrl, have_hfx, use_hfx ! whether or not to do an IC file too
  INTEGER it,itime,ntimes,ncid(MAXFILES),stat,iarg,narg,varid,strt(4),cnt(4),xtype,storeddim,dimids(4),natts
  REAL, EXTERNAL :: finterp
  INTEGER, EXTERNAL :: sec_of_day
  LOGICAL, EXTERNAL :: valid_date
  INTEGER sec, sec_start, sec_offset, nfiles
  REAL , PARAMETER :: g = 9.81 ! acceleration due to gravity (m {s}^-2)
  CHARACTER*32, DIMENSION(nbdys) :: bdynames

  REAL, DIMENSION(:,:,:), ALLOCATABLE :: zz & ! height in meters
       ,w & ! w at cell center
       ,ph & ! geop pert in wrf
       ,phb & ! geop base in wrf
       ,pres ! pressure in millibars
  ! half level WRF variables
  REAL, DIMENSION(:,:,:), ALLOCATABLE :: z & ! height in meters on cell ctrs
       ,p & ! pres pert in wrf
       ,pb & ! pres base in wrf
       ,t & ! temp in K
       ,u_ & ! staggered u_
       ,v_ & ! staggered v_
       ,u & ! u at cell center
       ,v ! v at cell center
  ! two-d WRF variables
  REAL, DIMENSION(:,:), ALLOCATABLE :: xlat, xlong , hfx
  ! temporaries
  REAL, DIMENSION(:,:,:), ALLOCATABLE :: zzcol
  REAL, DIMENSION(:,:,:), ALLOCATABLE :: zcol
  INTEGER kz(0:1,0:1), kzz(0:1,0:1), ibdy, ipoint
  REAL :: hfx_new, u_new, v_new, t_new, t_ground, pres_new, pd, w_new, theta, costheta, sintheta, dx
  REAL :: dx_check
  INTEGER :: ids_check , ide_check , jds_check , jde_check , kds_check , kde_check
  INTEGER :: i , j , k
  INTEGER :: ii, jj, kk
  
  ! borrowed from NCLS for computing T from Theta
  DOUBLE PRECISION P1000MB,R_D,CP, RHO0
  PARAMETER (P1000MB=100000.D0,R_D=266.9D0,CP=7.D0*R_D/2.D0)

  ! Exodus mesh (lat,lon) offset
  logical :: coord_offset
  real :: exo_lat_offset(1), exo_lon_offset(1), dmin, dsw
  integer :: exo_i_offset, exo_j_offset

  ! lat and lon of desired exodus point
  double precision exo_lat, exo_lon, exo_lz

  ! meshes and output files
  character(len=255), dimension(nbdys) :: meshname
  character(len=255), dimension(nbdys) :: ofname
  logical,            dimension(nbdys) :: exo_exists

  !================================================================================
  !
  ! Parse input arguments
  !
  !================================================================================

  ic = .FALSE.
  ic_is_written = .FALSE.
  use_hfx = .FALSE.
  it = 1
  itime  = 1
  ntimes = 1
  sec_offset = 0
  sec_start = 0
  coord_offset = .false.
  exo_lat_offset(1) = 0
  exo_lon_offset(1) = 0
  narg = iargc()

  IF ( narg .EQ. 0 ) THEN
     CALL help
     STOP 99
  ENDIF
  iarg = 1
  nfiles = 0
  DO WHILE ( .TRUE. )
     CALL getarg(iarg,arg)
     IF ( arg(1:1) .EQ. '-' ) THEN
        IF ( TRIM(arg) .EQ. '-startdate' ) THEN
           iarg = iarg + 1
           CALL getarg(iarg,arg)
           IF ( .NOT. valid_date( arg ) ) THEN
              WRITE(0,*)'Invalid data string in third argument to command: ',TRIM(arg)
              STOP 99
           ENDIF
           sec_start = sec_of_day(arg)
        ELSE IF ( TRIM(arg) .EQ. '-offset' ) THEN
           iarg = iarg + 1
           CALL getarg(iarg,arg)
           READ(arg,*)sec_offset
        ELSE IF ( TRIM(arg) .EQ. '-coord_offset' ) THEN
           coord_offset = .TRUE.
           iarg = iarg + 1
           CALL getarg(iarg,arg)
           READ(arg,*)exo_lat_offset(1)
           iarg = iarg + 1
           CALL getarg(iarg,arg)
           READ(arg,*)exo_lon_offset(1)
        ELSE IF ( TRIM(arg) .EQ. '-ic' ) THEN
           ic = .TRUE.
        ELSE IF ( TRIM(arg) .EQ. '-qwall' ) THEN
           use_hfx = .TRUE.
        ENDIF
     ELSE
        nfiles = nfiles + 1
        IF ( nfiles .GT. MAXFILES ) THEN
           write(0,*)'Too many input files'
           STOP
        ENDIF
        flnm(nfiles) = arg
     ENDIF
     iarg = iarg + 1
     IF ( iarg .GT. narg ) exit
  ENDDO

  bdynames(BDY_XS) = "west"
  bdynames(BDY_XE) = "east"
  bdynames(BDY_YS) = "south"
  bdynames(BDY_YE) = "north"
  bdynames(BDY_ZS) = "lower"
  bdynames(BDY_ZE) = "upper"
  bdynames(INTERIOR) = "interior"

  ! meshfiles and exodus output files
  do ibdy = 1, nbdys

     meshname(ibdy) = trim(bdynames(ibdy))//'.g'
     ofname(ibdy)   = trim(bdynames(ibdy))//'.e'
     inquire(file=trim(meshname(ibdy)), exist = exo_exists(ibdy))

     ! short circuit if we do not want to generate interior file
     if ( ibdy .eq. interior .and. .not. ic ) then
        exo_exists(ibdy) = .FALSE.
        cycle
     endif

     ! Copy the mesh file to an output file (if it exists)
     if (exo_exists(ibdy)) then
        comstr = "cp " // trim(meshname(ibdy))//" "//trim(ofname(ibdy))
        CALL system (trim(comstr))
     endif
  enddo  
  
  !================================================================================
  !
  ! WRF data: reading, allocating
  !
  !================================================================================

  ! Open files, get the mesh spacing and indices, and perform sanity checks
  DO i = 1, nfiles
     WRITE(0,*)'opening : flnm(i) ',i,TRIM(flnm(i))
     stat = NF_OPEN(flnm(i), NF_NOWRITE, ncid(i))
     CALL ncderrcheck( __FILE__, __LINE__ ,stat )
     stat=NF_GET_ATT_REAL(ncid(i),NF_GLOBAL,'DX',dx) ;
     IF( i .EQ. 1 ) dx_check = dx
     CALL ncderrcheck( __FILE__, __LINE__,stat )
     stat = NF_GET_ATT_INT (ncid(i),NF_GLOBAL,'WEST-EAST_PATCH_END_STAG',ide) ; ids = 1 ;
     IF( i .EQ. 1 ) ide_check = ide
     CALL ncderrcheck( __FILE__, __LINE__,stat )
     stat = NF_GET_ATT_INT (ncid(i),NF_GLOBAL,'SOUTH-NORTH_PATCH_END_STAG',jde) ; jds = 1 ;
     IF( i .EQ. 1 ) jde_check = jde
     CALL ncderrcheck( __FILE__, __LINE__,stat )
     stat = NF_GET_ATT_INT (ncid(i),NF_GLOBAL,'BOTTOM-TOP_PATCH_END_STAG',kde) ; kds = 1 ;
     IF( i .EQ. 1 ) kde_check = kde
     CALL ncderrcheck( __FILE__, __LINE__,stat )
     IF ( i .GT. 1 ) THEN
        stat = 0
        IF ( dx .NE. dx_check ) THEN
           stat = 1 ; write(0,*)'DX ',TRIM(flnm(i)),' does not match ',TRIM(flnm(i))
        ENDIF
        IF ( ide .NE. ide_check ) THEN
           stat = 1 ; write(0,*)'WEST-EAST_PATCH_END_STAG in ',TRIM(flnm(i)),' does not match ',TRIM(flnm(i))
        ENDIF
        IF ( jde .NE. jde_check ) THEN
           stat = 1 ; write(0,*)'SOUTH-NORTH_PATCH_END_STAG in ',TRIM(flnm(i)),' does not match ',TRIM(flnm(i))
        ENDIF
        IF ( kde .NE. kde_check ) THEN
           stat = 1 ; write(0,*)'BOTTOM-TOP_PATCH_END_STAG in ',TRIM(flnm(i)),' does not match ',TRIM(flnm(i))
        ENDIF
        IF ( stat .NE. 0 ) STOP
     ENDIF
  ENDDO

  strt = 1
  cnt(1) = 19

  ! Get info from the Times variable
  stat = NF_INQ_VARID(ncid,'Times',varid) ! get ID of variable Times
  CALL ncderrcheck( __FILE__, __LINE__,stat)
  stat = NF_INQ_VAR(ncid,varid,vname,xtype,storeddim,dimids,natts) ! get all information about Times
  CALL ncderrcheck( __FILE__, __LINE__,stat)
  stat = NF_INQ_DIMLEN(ncid,dimids(1),cnt(1))
  CALL ncderrcheck( __FILE__, __LINE__,stat)
  stat = NF_INQ_DIMLEN(ncid,dimids(2),cnt(2))
  CALL ncderrcheck( __FILE__, __LINE__,stat)
  stat = NF_GET_VARA_TEXT(ncid,varid,strt,cnt,Times) ! read in the Times data in the Times text
  CALL ncderrcheck( __FILE__, __LINE__,stat )
  ntimes = cnt(2)
  
  ! Allocate a lot of variables
  ips = ids ; ipe = ide
  jps = jds ; jpe = jde
  kps = kds ; kpe = kde
  ims = ids ; ime = ide
  jms = jds ; jme = jde
  kms = kds ; kme = kde

  ALLOCATE( xlat(ips:ipe-1,jps:jpe-1))
  ALLOCATE( xlong(ips:ipe-1,jps:jpe-1))
  ctrl = .TRUE. ! true value going in says this field is required
  CALL getvar_real(ctrl,ncid,nfiles,'XLAT' ,xlat ,it,2,ips,ipe-1,jps,jpe-1,1,1)
  CALL getvar_real(ctrl,ncid,nfiles,'XLONG',xlong,it,2,ips,ipe-1,jps,jpe-1,1,1)

  ! Define an offset (lat,long) for the Exodus mesh
  if ( .not. coord_offset ) then
     exo_lat_offset(1) = minval(xlat)  + 0.5*(maxval(xlat) - minval(xlat))
     exo_lon_offset(1) = minval(xlong) + 0.5*(maxval(xlong) - minval(xlong))
  else

     ! If it was already set then, check to make sure it is within the
     ! WRF data set
     if ( (exo_lat_offset(1) .le. minval(xlat)) .or. &
          (exo_lat_offset(1) .ge. maxval(xlat)) .or. &
          (exo_lon_offset(1) .le. minval(xlong)) .or. &
          (exo_lon_offset(1) .ge. maxval(xlong)) ) then
        
        write(0,*)"Offset (lat,lon) are not contained in the WRF data set"
        write(0,*)"Offset (lat,lon)=", exo_lat_offset, exo_lon_offset
        write(0,*)"WRF data bounds min (lat,lon)=", minval(xlat), minval(xlong)
        write(0,*)"                max (lat,lon)=", maxval(xlat), maxval(xlong)
        stop 99

     endif
  endif

  ! Find (i,j) point correpsonding to this (0,0)
  ! really only for diagnostic purposes
  dmin = 999999.9
  ! loop on WRF data
  do j = jps,min(jpe,jde-2)
     do i = ips,min(ipe,ide-2)
        dsw = sqrt((exo_lat_offset(1)-xlat(i ,j ))*(exo_lat_offset(1)-xlat(i ,j )) + (exo_lon_offset(1)-xlong(i ,j ))*(exo_lon_offset(1)-xlong(i ,j )))
        if ( dsw .lt. dmin .and. exo_lat_offset(1) .ge. xlat(i,j) .and. exo_lon_offset(1) .ge. xlong(i,j) ) then
           exo_i_offset = i
           exo_j_offset = j
           dmin = dsw
        endif
     enddo
  enddo
  write(0,*)"Exodus offset (lat,lon) = ", exo_lat_offset(1), exo_lon_offset(1)
  write(0,*)"     corresponding to WRF (i,j) = ", exo_i_offset, exo_j_offset

  theta = rotation_angle ( xlat,dx,ids,ide,jds,jde,ips,ipe,jps,jpe,ims,ime,jms,jme )
  ! Computed theta is counterclockwise rotation in radians of the vector from X axis, so negate and
  ! convert to degrees for reporting rotation with respect to compass points
  write(*,'("WRF grid is clockwise rotated approx.",f9.5," deg. from true lat/lon. Compensating.")'),-theta*57.2957795
  costheta = cos(theta)
  sintheta = sin(theta)

  ALLOCATE( p(ips:ipe-1,jps:jpe-1,kps:kpe-1))
  ALLOCATE( pb(ips:ipe-1,jps:jpe-1,kps:kpe-1))
  ALLOCATE( ph(ips:ipe-1,jps:jpe-1,kps:kpe ))
  ALLOCATE( phb(ips:ipe-1,jps:jpe-1,kps:kpe ))
  ALLOCATE( zz(ips:ipe-1,jps:jpe-1,kps:kpe ))
  ALLOCATE( w(ips:ipe-1,jps:jpe-1,kps:kpe ))
  ALLOCATE( pres(ips:ipe-1,jps:jpe-1,kps:kpe-1))
  ALLOCATE( z(ips:ipe-1,jps:jpe-1,kps:kpe-1))
  ALLOCATE( t(ips:ipe-1,jps:jpe-1,kps:kpe-1))
  ALLOCATE( u(ips:ipe-1,jps:jpe-1,kps:kpe-1))
  ALLOCATE( v(ips:ipe-1,jps:jpe-1,kps:kpe-1))
  ALLOCATE( u_(ips:ipe ,jps:jpe-1,kps:kpe-1))
  ALLOCATE( v_(ips:ipe-1,jps:jpe ,kps:kpe-1))
  ALLOCATE(zzcol(0:1,0:1,kps:kpe ))
  ALLOCATE( zcol(0:1,0:1,kps:kpe-1))
  ALLOCATE( hfx(ips:ipe-1,jps:jpe-1))

  p = 0.
  pb = 0.
  ph = 0.
  phb = 0.
  zz = 0.
  w = 0.
  pres = 0.
  z = 0.
  t = 0.
  u = 0.
  v = 0.
  u_ = 0.
  v_ = 0.
  zzcol = 0.
  zcol = 0.
  hfx = 0.

  !================================================================================
  !
  ! Exodus mesh: prep and relate to WRF data
  !
  !================================================================================
  do ibdy = 1, nbdys
     if (exo_exists(ibdy)) then
        ! Prepare the output file
        call prep_exodus(ibdy, trim(ofname(ibdy)), ibdy .eq. BDY_ZS .and. have_hfx .and. use_hfx)

        ! Read the mesh body
        call read_exodus_bdy_coords( ibdy, exo_lat_offset, exo_lon_offset)

        ! For each mesh (lat,lon), find the closest point in the WRF dataset
        call relate_exodus_wrf( ibdy ,xlat,xlong,ids,ide,jds,jde,ips,ipe,jps,jpe,ims,ime,jms,jme)
     endif
  enddo
  
  !================================================================================
  !
  ! Interpolate WRF data to the Exodus mesh
  !
  !================================================================================
  
  do itime = 1,ntimes

     !================================================================================
     ! WRF data
     
     ! time
     DO WHILE (.TRUE.) ! just replace ':' char by '_' in the Times variable
        tmpstr = Times(itime)
        i = INDEX(Times(itime),':')
        IF ( i .EQ. 0 ) EXIT
        Times(itime)(i:i) = '_'
     ENDDO

     sec = sec_of_day(TRIM(Times(itime)))
     sec = sec - sec_start + sec_offset
     IF ( sec > 999999 ) THEN
        WRITE(0,*)sec,' is too many seconds from start.'
        WRITE(0,*)'Use -offset argument to make this a six digit number.'
        CALL help
        STOP 99
     ENDIF
     WRITE(secstr,'(I6.1)')sec

     ! variables
     CALL getvar_real(ctrl,ncid,nfiles,'PH' ,ph ,itime,3,ips,ipe-1,jps,jpe-1,kps,kpe )
     CALL getvar_real(ctrl,ncid,nfiles,'PHB',phb,itime,3,ips,ipe-1,jps,jpe-1,kps,kpe )
     CALL getvar_real(ctrl,ncid,nfiles,'W' ,w   ,itime,3,ips,ipe-1,jps,jpe-1,kps,kpe )
     CALL getvar_real(ctrl,ncid,nfiles,'T' ,t   ,itime,3,ips,ipe-1,jps,jpe-1,kps,kpe-1)
     CALL getvar_real(ctrl,ncid,nfiles,'U' ,u_  ,itime,3,ips,ipe  ,jps,jpe-1,kps,kpe-1)
     CALL getvar_real(ctrl,ncid,nfiles,'V' ,v_  ,itime,3,ips,ipe-1,jps,jpe  ,kps,kpe-1)
     CALL getvar_real(ctrl,ncid,nfiles,'P' ,p   ,itime,3,ips,ipe-1,jps,jpe-1,kps,kpe-1)
     CALL getvar_real(ctrl,ncid,nfiles,'PB' ,pb ,itime,3,ips,ipe-1,jps,jpe-1,kps,kpe-1)

     have_hfx = .FALSE. ! false value going in says this field is not required
     CALL getvar_real(have_hfx,ncid,nfiles,'HFX',hfx,itime,3,ips,ipe-1,jps,jpe-1,1,1)

     zz = (ph + phb )/g
     z = (zz(:,:,kps:kpe-1) + zz(:,:,kps+1:kpe))*0.5
     u = (u_(ips:ipe-1,:,:)+u_(ips+1:ipe,:,:))*0.5
     v = (v_(:,jps:jpe-1,:)+v_(:,jps+1:jpe,:))*0.5

     pres = p + pb

     t = t+300.


     !================================================================================
     ! Interpolation
     do ibdy = 1, nbdys
        if (exo_exists(ibdy)) then

           ! Only write the interior once
           if ( ibdy .eq. interior .and. ic_is_written) cycle
           
           ! Interpolation to WRF data
           do ipoint = 1, bdy(ibdy)%num_nodes

              ! Exodus point information
              exo_lat = bdy(ibdy)%lat(ipoint)
              exo_lon = bdy(ibdy)%lon(ipoint)
              exo_lz = bdy(ibdy)%coordz(ipoint)
              j = bdy(ibdy)%exo_wrf_j(ipoint)
              i = bdy(ibdy)%exo_wrf_i(ipoint)

              DO kk = 1,size(zz,3)
                 DO jj = 0,1
                    DO ii = 0,1
                       zzcol(ii,jj,kk)=zz(i+ii,j+jj,kk) - zz(i+ii,j+jj,1) ! zz is full height at cell centers
                       IF ( kk .LE. kpe-1 ) THEN
                          zcol (ii,jj,kk)= z(i+ii,j+jj,kk) - zz(i+ii,j+jj,1) ! z is half height at cell centers
                       ENDIF
                    ENDDO
                 ENDDO
              ENDDO

              ! find the level index of the exodus point in WRF, both in the full-level
              ! and half-level ranges. Lowest index is closest to surface. Also store the
              ! indices for the 3 neighbors to the north, east, and northeast, since these
              ! are needed for horizontally interpolating in the finterp function
              DO jj = 0,1
                 DO ii = 0,1
                    IF (zzcol(ii,jj,1).LE.exo_lz.AND.exo_lz.LT.zcol(ii,jj,1))THEN ! special case, exo_lz is below first half-level
                       kzz(ii,jj) = 1 ! ignore other special case since exodus wont go that high
                       kz(ii,jj) = 0
                    ELSE
                       DO k = kps+1,kpe
                          IF (zzcol(ii,jj,k-1).LE.exo_lz.AND.exo_lz.LT.zzcol(ii,jj,k)) kzz(ii,jj) = k-1 ! full level
                          IF (k.LT.kpe) THEN
                             IF (zcol(ii,jj,k-1).LE.exo_lz.AND.exo_lz.LT.zcol(ii,jj,k)) kz(ii,jj) = k-1 ! half level
                          ENDIF
                       ENDDO
                    ENDIF
                 ENDDO
              ENDDO

              !variables on half-levels exodus coords dims of field dims of lat lon arrays
              u_new    = finterp(u   , zcol,xlat,xlong,kz ,exo_lat,exo_lon,exo_lz,i,j,ips,ipe-1,jps,jpe-1,kps,kpe-1, ips,ipe-1,jps,jpe-1)
              v_new    = finterp(v   , zcol,xlat,xlong,kz ,exo_lat,exo_lon,exo_lz,i,j,ips,ipe-1,jps,jpe-1,kps,kpe-1, ips,ipe-1,jps,jpe-1)
              t_new    = finterp(t   , zcol,xlat,xlong,kz ,exo_lat,exo_lon,exo_lz,i,j,ips,ipe-1,jps,jpe-1,kps,kpe-1, ips,ipe-1,jps,jpe-1)
              pres_new = finterp(pres,zzcol,xlat,xlong,kzz,exo_lat,exo_lon,exo_lz,i,j,ips,ipe-1,jps,jpe-1,kps,kpe-1, ips,ipe-1,jps,jpe-1)

              !variables on full-levels exodus coords dims of field dims of lat lon arrays
              w_new    = finterp(w   ,zzcol,xlat,xlong,kzz,exo_lat,exo_lon,exo_lz,i,j,ips,ipe-1,jps,jpe-1,kps,kpe  , ips,ipe-1,jps,jpe-1)
              t_ground = t(i,j,1)
              ! compute "pd" which is defined as pressure divided by density at surface minus geopotential
              ! that is, pd = p / rho - g*z . Note, however, that we don.t have density so compute density at
              ! surface as rho0 = p0 / (R*T0), where R is 286.9 and T0 is surface temp. Substituting for rho
              ! into the above, this becomes:
              pd = (pres_new*R_D*t_ground)/pres(i,j,1) - g * exo_lz

              ! Save the variables
              ! cont_velocity_bc_x
              bdy(ibdy)%vals_nod_var1(ipoint) = u_new*costheta-v_new*sintheta
              ! cont_velocity_bc_y
              bdy(ibdy)%vals_nod_var2(ipoint) = u_new*sintheta+v_new*costheta
              ! cont_velocity_bc_z
              bdy(ibdy)%vals_nod_var3(ipoint) = w_new
              ! temperature_bc
              bdy(ibdy)%vals_nod_var4(ipoint) = t_new
              ! velocity_bc_x
              bdy(ibdy)%vals_nod_var5(ipoint) = u_new*costheta-v_new*sintheta
              ! velocity_bc_y
              bdy(ibdy)%vals_nod_var6(ipoint) = u_new*sintheta+v_new*costheta
              ! velocity_bc_z
              bdy(ibdy)%vals_nod_var7(ipoint) = w_new

              ! heat flux if we want it
              if ( bdy(ibdy)%using_hfx ) then
                 kzz = 0 ! turn off vertical interpolation in call to finterp
                 hfx_new = finterp(hfx,zzcol,xlat,xlong,kzz,exo_lat,exo_lon,exo_lz,i,j,ips,ipe-1,jps,jpe-1,1,1, ips,ipe-1,jps,jpe-1)
                 rho0 = pres(i,j,1) / ( R_D * t_ground )
                 hfx_new = -( hfx_new / ( rho0 * CP ) )

                 bdy(ibdy)%vals_nod_var8(ipoint) = hfx_new
              endif

           enddo

           ! Write out variables to the file
           call write_vars_exodus( ibdy, itime, sec )

           ! Only write the interior once
           if ( ibdy .eq. interior) ic_is_written = .true.
           
        endif
     enddo
  enddo


  !================================================================================
  !
  ! Clean up
  !
  !================================================================================
  do ibdy = 1, nbdys
     if (exo_exists(ibdy)) then
        call close_exodus(ibdy)
     endif
  enddo

  deallocate(zz)
  deallocate(w)
  deallocate(ph)
  deallocate(phb)
  deallocate(pres)
  deallocate(z)
  deallocate(p)
  deallocate(pb)
  deallocate(t)
  deallocate(u_)
  deallocate(v_)
  deallocate(u)
  deallocate(v)
  deallocate(xlat)
  deallocate(xlong)
  deallocate(hfx)
  deallocate(zzcol)
  deallocate(zcol)
  
  ! Let the user know we are done here
  write(*,*)'Conversion done.'
  
END PROGRAM wrftonalu

!--------------------------------------------------------------------------------
!
!> @brief finterp interpolates WRF data at Exodus nodes
!> @param f        variable to interpolate
!> @param zcol     
!> @param lat      latitude
!> @param lon      longitude
!> @param kz       
!> @param of_lat   latitude of desired exodus point
!> @param of_lon   longitude of desired exodus point
!> @param of_lz    height of desired exodus point
!> @param i        precomputed icoord of cell center corresponding to lon
!> @param j        precomputed jcoord of cell center corresponding to lat
!> @param is       start i index
!> @param ie       end i index   
!> @param js       start j index 
!> @param je       end j index   
!> @param ks       start k index 
!> @param ke       end k index   
!> @param ims
!> @param ime
!> @param jms
!> @param jme
!
!--------------------------------------------------------------------------------
REAL FUNCTION finterp( f, zcol, lat, lon, kz, of_lat, of_lon, of_lz, i, j, is,ie,js,je,ks,ke,ims,ime,jms,jme )
  IMPLICIT NONE
  INTEGER, INTENT(IN) :: i,j,is,ie,js,je,ks,ke,ims,ime,jms,jme
  INTEGER, INTENT(IN) :: kz(0:1,0:1)
  REAL, INTENT(IN) :: f(is:ie,js:je,ks:ke), zcol(0:1,0:1,ks:ke)
  DOUBLE PRECISION, INTENT(IN) :: of_lat, of_lon, of_lz
  REAL, INTENT(IN) :: lat(ims:ime,jms:jme),lon(ims:ime,jms:jme)
  ! local
  INTEGER k
  REAL f00,f10,f01,f11,rm
  k = kz(0,0)
  IF ( k .GE. 1 ) THEN
     f00 = f(i ,j ,k) + (of_lz-zcol(0 ,0 ,k))*(f(i ,j ,k+1)-f(i ,j ,k))/(zcol(0 ,0 ,k+1)-zcol(0 ,0 ,k))
  ELSE
     f00 = f(i ,j ,1)
  ENDIF
  k = kz(1,0)
  IF ( k .GE. 1 ) THEN
     f10 = f(i+1,j ,k) + (of_lz-zcol(0+1,0 ,k))*(f(i+1,j ,k+1)-f(i+1,j ,k))/(zcol(0+1,0 ,k+1)-zcol(0+1,0 ,k))
  ELSE
     f10 = f(i+1,j ,1)
  ENDIF
  k = kz(0,1)
  IF ( k .GE. 1 ) THEN
     f01 = f(i ,j+1,k) + (of_lz-zcol(0 ,0+1,k))*(f(i ,j+1,k+1)-f(i ,j+1,k))/(zcol(0 ,0+1,k+1)-zcol(0 ,0+1,k))
  ELSE
     f01 = f(i ,j+1,1)
  ENDIF
  k = kz(1,1)
  IF ( k .GE. 1 ) THEN
     f11 = f(i+1,j+1,k) + (of_lz-zcol(0+1,0+1,k))*(f(i+1,j+1,k+1)-f(i+1,j+1,k))/(zcol(0+1,0+1,k+1)-zcol(0+1,0+1,k))
  ELSE
     f11 = f(i+1,j+1,1)
  ENDIF
  !
  rm = 1.0/((lon(i+1,j)-lon(i,j))*(lat(i,j+1)-lat(i,j)))
  finterp = f00*rm*(lon(i+1,j)-of_lon )*(lat(i,j+1)-of_lat ) + &
       f10*rm*(of_lon -lon(i,j))*(lat(i,j+1)-of_lat ) + &
       f01*rm*(lon(i+1,j)-of_lon )*(of_lat -lat(i,j)) + &
       f11*rm*(of_lon -lon(i,j))*(of_lat -lat(i,j))
  RETURN
END FUNCTION finterp


!--------------------------------------------------------------------------------
!
!> @brief Help function for command line usage
!
!--------------------------------------------------------------------------------
SUBROUTINE help
  IMPLICIT NONE
  CHARACTER(LEN=120) :: cmd
  CALL getarg(0, cmd)
  WRITE(*,'(/,"Usage: ", A, " ncdfile [ncdfiles*] [-startdate startdate [-offset offset] [-coord_offset lat lon]] [-ic] [-qwall]")') trim(cmd)
  WRITE(*,'("       startdate     date string of form yyyy-mm-dd_hh_mm_ss or yyyy-mm-dd_hh:mm:ss")')
  WRITE(*,'("       offset        number of seconds to start Exodus directory naming (default: 0)")')
  WRITE(*,'("       lat           latitude of origin for the Exodus mesh (default: center of WRF data)")')
  WRITE(*,'("       lon           longitude of origin for the Exodus mesh (default: center of WRF data)")')
  WRITE(*,'("       -ic           program should generate init conditions too")')
  WRITE(*,'("       -qwall        program should generate temp flux in lower bc file ",/)')
  STOP
END SUBROUTINE help


!--------------------------------------------------------------------------------
!
!> @brief Read data in netCDF file
!> @param ctrl      is this field required?
!> @param ncids     netCDF file identifier
!> @param numfiles  number of files to read
!> @param vname     variable name to be read
!> @param buf       where to put the variable
!> @param itime     time step to read the variable
!> @param ndim      number of dimensions
!> @param ids       start i index
!> @param ide       end i index   
!> @param jds       start j index 
!> @param jde       end j index   
!> @param kds       start k index 
!> @param kde       end k index   
!
!--------------------------------------------------------------------------------
SUBROUTINE getvar_real(ctrl,ncids,numfiles,vname,buf,itime,ndim,ids,ide,jds,jde,kds,kde)
  IMPLICIT NONE
  INCLUDE 'netcdf.inc'
  INTEGER, INTENT(IN), DIMENSION(*) :: ncids
  INTEGER, INTENT(IN) :: numfiles
  LOGICAL, INTENT(INOUT):: ctrl
  REAL, INTENT(INOUT) :: buf(*)
  CHARACTER*(*), INTENT(IN) :: vname
  INTEGER, INTENT(IN) :: itime,ndim,ids,ide,jds,jde,kds,kde
  INTEGER strt(4),cnt(4)
  INTEGER stat,varid, i,ncid
  LOGICAL found
  !
  found = .FALSE.
  DO i = 1,numfiles
     ncid = ncids(i)
     IF ( ncid .GT. 0 .AND. .NOT. found ) THEN
        stat = NF_INQ_VARID(ncid,vname,varid)
        IF ( stat .EQ. 0 ) THEN
           strt = 1
           strt(4) = itime
           IF ( ndim .EQ. 3 ) THEN
              cnt(1) = ide-ids+1
              cnt(2) = jde-jds+1
              cnt(3) = kde-kds+1
              cnt(4) = 1
           ELSE
              cnt(1) = ide-ids+1
              cnt(2) = jde-jds+1
              cnt(3) = 1
           ENDIF
           stat = NF_GET_VARA_REAL(ncid,varid,strt,cnt,buf)
           IF ( stat .EQ. 0 ) found = .TRUE.
        ENDIF
     ENDIF
  ENDDO
  IF ( .NOT. found .AND. ctrl ) THEN
     WRITE(0,*)'getvar_real: did not find ',TRIM(vname),' in any input file'
     STOP 99
  ENDIF
  ctrl = found
  RETURN
END SUBROUTINE getvar_real

!--------------------------------------------------------------------------------
!
!> @brief Find the second of the day
!> @param s        seconds
!> @warning OVERLY SIMPLE -- assumes same day! and assumes 19 char WRF style date str
!
!--------------------------------------------------------------------------------
INTEGER FUNCTION sec_of_day ( s )
  IMPLICIT NONE
  CHARACTER*(*), INTENT(IN) :: s
  INTEGER hh,mm,ss
  ! 0000000001111111111
  ! 1234567890123456789
  ! 2005-01-15_02_04_31
  READ(s(12:13),*)hh
  READ(s(15:16),*)mm
  READ(s(18:19),*)ss
  sec_of_day = hh*3600 + mm*60 + ss
END FUNCTION sec_of_day


!--------------------------------------------------------------------------------
!
!> @brief Check if this is a valid date
!> @param s    seconds
!
!--------------------------------------------------------------------------------
LOGICAL FUNCTION valid_date ( s )
  IMPLICIT NONE
  CHARACTER*(*), INTENT(IN) :: s
  LOGICAL, EXTERNAL :: isnum
  LOGICAL retval
  retval = .FALSE.
  IF ( LEN(TRIM(s)) .EQ. 19 ) THEN
     IF ( isnum(1,s) .AND. isnum(2,s) .AND. isnum(3,s) .AND. isnum(4,s) .AND. &
          s(5:5).EQ.'-' .AND. &
          isnum(6,s) .AND. isnum(7,s) .AND. &
          s(8:8).EQ.'-' .AND. &
          isnum(9,s) .AND. isnum(10,s) .AND. &
          s(11:11).EQ.'_' .AND. &
          isnum(12,s) .AND. isnum(13,s) .AND. &
          (s(14:14).EQ.'_' .OR. s(14:14).EQ.':') .AND. &
          isnum(15,s) .AND. isnum(16,s) .AND. &
          (s(17:17).EQ.'_' .OR. s(17:17).EQ.':') .AND. &
          isnum(18,s) .AND. isnum(19,s) ) THEN
        retval = .TRUE.
     ENDIF
  ENDIF
  valid_date = retval
END FUNCTION valid_date


!--------------------------------------------------------------------------------
!
!> @brief Is the string a number?
!> @param i    integer
!> @param str  string
!
!--------------------------------------------------------------------------------
LOGICAL FUNCTION isnum ( i, str )
  IMPLICIT NONE
  INTEGER, INTENT(IN) :: i
  CHARACTER*(*), INTENT(IN) :: str
  isnum = (ICHAR('0').LE. ICHAR(str(i:i)).AND.ICHAR(str(i:i)) .LE. ICHAR('9'))
END FUNCTION isnum
