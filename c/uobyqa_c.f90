module uobyqa_c_mod
!--------------------------------------------------------------------------------------------------!
! uobyqa_c_mod provides uobyqa_c, a simplified interface to cobyla for interoperability with C
!
! Dedicated to the late Professor M. J. D. Powell FRS (1936--2015).
!--------------------------------------------------------------------------------------------------!
implicit none
private
public :: uobyqa_c


contains


subroutine uobyqa_c(cobj_ptr, data_ptr, n, x, f, nf, rhobeg, rhoend, ftarget, maxfun, iprint, info) bind(C)
use, intrinsic :: iso_c_binding, only : C_DOUBLE, C_INT, C_FUNPTR, C_PTR
use, non_intrinsic :: cintrf_mod, only : COBJ
use, non_intrinsic :: consts_mod, only : RP, IK
use, non_intrinsic :: uobyqa_mod, only : uobyqa
implicit none

! Compulsory arguments
type(C_FUNPTR), intent(IN), value :: cobj_ptr
type(C_PTR), intent(in), value :: data_ptr
integer(C_INT), intent(in), value :: n
! We cannot use assumed-shape arrays for C interoperability
real(C_DOUBLE), intent(inout) :: x(n)
real(C_DOUBLE), intent(out) :: f
integer(C_INT), intent(out) :: nf
real(C_DOUBLE), intent(in), value :: rhobeg
real(C_DOUBLE), intent(in), value :: rhoend
real(C_DOUBLE), intent(in), value :: ftarget
integer(C_INT), intent(in), value :: maxfun
integer(C_INT), intent(in), value :: iprint
integer(C_INT), intent(out) :: info

! Local variables
integer(IK) :: info_loc
integer(IK) :: iprint_loc
integer(IK) :: maxfun_loc
integer(IK) :: nf_loc
real(RP) :: f_loc
real(RP) :: rhobeg_loc
real(RP) :: rhoend_loc
real(RP) :: ftarget_loc
real(RP) :: x_loc(n)

! Read the inputs and convert them to the Fortran side types
x_loc = real(x, kind(x_loc))
rhobeg_loc = real(rhobeg, kind(rhobeg))
rhoend_loc = real(rhoend, kind(rhoend))
ftarget_loc = real(ftarget, kind(ftarget))
maxfun_loc = int(maxfun, kind(maxfun_loc))
iprint_loc = int(iprint, kind(iprint_loc))

! Call the Fortran code
call uobyqa(calfun, x_loc, f_loc, nf=nf_loc, rhobeg=rhobeg_loc, rhoend=rhoend_loc, ftarget=ftarget_loc, &
    & maxfun=maxfun_loc, iprint=iprint_loc, info=info_loc)

! Write the outputs
x = real(x_loc, kind(x))
f = real(f_loc, kind(f))
nf = int(nf_loc, kind(nf))
info = int(info_loc, kind(info))

contains

!--------------------------------------------------------------------------------------------------!
! This subroutine defines `calfun` using the C function pointer with an internal subroutine.
! This allows to avoid passing the C function pointer by a module variable, which is thread-unsafe.
! A possible security downside is that the compiler must allow for an executable stack.
!--------------------------------------------------------------------------------------------------!
subroutine calfun(x_sub, f_sub)
use, non_intrinsic :: consts_mod, only : RP
use, non_intrinsic :: cintrf_mod, only : evalcobj
implicit none
real(RP), intent(in) :: x_sub(:)
real(RP), intent(out) :: f_sub
call evalcobj(cobj_ptr, data_ptr, x_sub, f_sub)
end subroutine calfun

end subroutine uobyqa_c


end module uobyqa_c_mod
