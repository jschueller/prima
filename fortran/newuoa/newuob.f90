module newuob_mod
!--------------------------------------------------------------------------------------------------!
! This module performs the major calculations of NEWUOA.
!
! Coded by Zaikun ZHANG (www.zhangzk.net) based on Powell's code and the NEWUOA paper.
!
! Dedicated to late Professor M. J. D. Powell FRS (1936--2015).
!
! Started: July 2020
!
! Last Modified: Saturday, February 11, 2023 PM10:58:19
!--------------------------------------------------------------------------------------------------!

implicit none
private
public :: newuob


contains


subroutine newuob(calfun, iprint, maxfun, npt, eta1, eta2, ftarget, gamma1, gamma2, rhobeg, &
    & rhoend, x, nf, f, fhist, xhist, info)
!--------------------------------------------------------------------------------------------------!
! This subroutine performs the actual calculations of NEWUOA.
!
! IPRINT, MAXFUN, MAXHIST, NPT, ETA1, ETA2, FTARGET, GAMMA1, GAMMA2, RHOBEG, RHOEND, X, NF, F,
! FHIST, XHIST, and INFO are identical to the corresponding arguments in subroutine NEWUOA.
!
! XBASE holds a shift of origin that should reduce the contributions from rounding errors to values
!   of the model and Lagrange functions.
! XOPT is the displacement from XBASE of the best vector of variables so far (i.e., the one provides
!   the least calculated F so far). FOPT = F(XOPT + XBASE).
! D is reserved for trial steps from XOPT.
! [XPT, FVAL, KOPT] describes the interpolation set:
! XPT contains the interpolation points relative to XBASE, each COLUMN for a point; FVAL holds the
!   values of F at the interpolation points; KOPT is the index of XOPT in XPT.
! [GQ, HQ, PQ] describes the quadratic model: GQ will hold the gradient of the quadratic model at
!   XBASE; HQ will hold the explicit second order derivatives of the quadratic model; PQ will
!   contain the parameters of the implicit second order derivatives of the quadratic model.
! [BMAT, ZMAT, IDZ] describes the matrix H in the NEWUOA paper (eq. 3.12), which is the inverse of
!   the coefficient matrix of the KKT system for the least-Frobenius norm interpolation problem:
!   ZMAT will hold a factorization of the leading NPT*NPT submatrix of H, the factorization being
!   ZMAT*Diag(DZ)*ZMAT^T with DZ(1:IDZ-1)=-1, DZ(IDZ:NPT-N-1)=1. BMAT will hold the last N ROWs of H
!   except for the (NPT+1)th column. Note that the (NPT + 1)th row and column of H are not saved as
!   they are unnecessary for the calculation.
!
! See Section 2 of the NEWUOA paper for more information about these variables.
!--------------------------------------------------------------------------------------------------!

! Generic modules
use, non_intrinsic :: checkexit_mod, only : checkexit
use, non_intrinsic :: consts_mod, only : RP, IK, ONE, HALF, TENTH, HUGENUM, DEBUGGING
use, non_intrinsic :: debug_mod, only : assert
use, non_intrinsic :: evaluate_mod, only : evaluate
use, non_intrinsic :: history_mod, only : savehist, rangehist
use, non_intrinsic :: infnan_mod, only : is_nan, is_posinf
use, non_intrinsic :: infos_mod, only : INFO_DFT, MAXTR_REACHED, SMALL_TR_RADIUS
use, non_intrinsic :: linalg_mod, only : norm, matprod
use, non_intrinsic :: output_mod, only : retmsg, rhomsg, fmsg
use, non_intrinsic :: pintrf_mod, only : OBJ
use, non_intrinsic :: powalg_mod, only : quadinc, updateh
use, non_intrinsic :: ratio_mod, only : redrat
use, non_intrinsic :: redrho_mod, only : redrho
use, non_intrinsic :: shiftbase_mod, only : shiftbase

! Solver-specific modules
use, non_intrinsic :: geometry_mod, only : setdrop_tr, geostep
use, non_intrinsic :: initialize_mod, only : initxf, initq, inith
use, non_intrinsic :: trustregion_mod, only : trsapp, trrad
use, non_intrinsic :: update_mod, only : updatexf!, updateq, tryqalt

implicit none

! Inputs
procedure(OBJ) :: calfun  ! N.B.: INTENT cannot be specified if a dummy procedure is not a POINTER
integer(IK), intent(in) :: iprint
integer(IK), intent(in) :: maxfun
integer(IK), intent(in) :: npt
real(RP), intent(in) :: eta1
real(RP), intent(in) :: eta2
real(RP), intent(in) :: ftarget
real(RP), intent(in) :: gamma1
real(RP), intent(in) :: gamma2
real(RP), intent(in) :: rhobeg
real(RP), intent(in) :: rhoend

! In-outputs
real(RP), intent(inout) :: x(:)      ! X(N)

! Outputs
integer(IK), intent(out) :: info
integer(IK), intent(out) :: nf
real(RP), intent(out) :: f
real(RP), intent(out) :: fhist(:)   ! FHIST(MAXFHIST)
real(RP), intent(out) :: xhist(:, :)    ! XHIST(N, MAXXHIST)

! Local variables
character(len=*), parameter :: solver = 'NEWUOA'
character(len=*), parameter :: srname = 'NEWUOB'
integer(IK) :: idz
integer(IK) :: ij(2, max(0_IK, int(npt - 2 * size(x) - 1, IK)))
integer(IK) :: itest
integer(IK) :: knew_geo
integer(IK) :: knew_tr
integer(IK) :: kopt
integer(IK) :: maxfhist
integer(IK) :: maxhist
integer(IK) :: maxtr
integer(IK) :: maxxhist
integer(IK) :: n
integer(IK) :: subinfo
integer(IK) :: tr
logical :: accurate_mod
logical :: adequate_geo
logical :: bad_trstep
logical :: close_itpset
logical :: improve_geo
logical :: reduce_rho
logical :: shortd
logical :: small_trrad
logical :: ximproved
real(RP) :: bmat(size(x), npt + size(x))
real(RP) :: crvmin
real(RP) :: d(size(x))
real(RP) :: delbar
real(RP) :: delta
real(RP) :: distsq(npt)
real(RP) :: dnorm
real(RP) :: dnormsav(3)
real(RP) :: fopt
real(RP) :: fval(npt)
real(RP) :: gq(size(x)), gopt(size(x))
real(RP) :: hq(size(x), size(x))
real(RP) :: moderr
real(RP) :: moderrsav(size(dnormsav))
real(RP) :: pq(npt)
real(RP) :: qred
real(RP) :: ratio
real(RP) :: rho
real(RP) :: xbase(size(x))
real(RP) :: xdrop(size(x))
real(RP) :: xopt(size(x)), xosav(size(x))
real(RP) :: xpt(size(x), npt)
real(RP) :: zmat(npt, npt - size(x) - 1)
real(RP), parameter :: trtol = 1.0E-2_RP  ! Tolerance used in TRSAPP.

! Sizes
n = int(size(x), kind(n))
maxxhist = int(size(xhist, 2), kind(maxxhist))
maxfhist = int(size(fhist), kind(maxfhist))
maxhist = max(maxxhist, maxfhist)

! Preconditions
if (DEBUGGING) then
    call assert(abs(iprint) <= 3, 'IPRINT is 0, 1, -1, 2, -2, 3, or -3', srname)
    call assert(n >= 1 .and. npt >= n + 2, 'N >= 1, NPT >= N + 2', srname)
    call assert(maxfun >= npt + 1, 'MAXFUN >= NPT + 1', srname)
    call assert(rhobeg >= rhoend .and. rhoend > 0, 'RHOBEG >= RHOEND > 0', srname)
    call assert(eta1 >= 0 .and. eta1 <= eta2 .and. eta2 < 1, '0 <= ETA1 <= ETA2 < 1', srname)
    call assert(gamma1 > 0 .and. gamma1 < 1 .and. gamma2 > 1, '0 < GAMMA1 < 1 < GAMMA2', srname)
    call assert(maxhist >= 0 .and. maxhist <= maxfun, '0 <= MAXHIST <= MAXFUN', srname)
    call assert(maxfhist * (maxfhist - maxhist) == 0, 'SIZE(FHIST) == 0 or MAXHIST', srname)
    call assert(size(xhist, 1) == n .and. maxxhist * (maxxhist - maxhist) == 0, &
        & 'SIZE(XHIST, 1) == N, SIZE(XHIST, 2) == 0 or MAXHIST', srname)
end if

!====================!
! Calculation starts !
!====================!

! Initialize XBASE, XPT, FVAL, and KOPT.
call initxf(calfun, iprint, maxfun, ftarget, rhobeg, x, ij, kopt, nf, fhist, fval, xbase, xhist, xpt, subinfo)
xopt = xpt(:, kopt)
fopt = fval(kopt)
x = xbase + xopt
f = fopt

! Check whether to return due to abnormal cases that may occur during the initialization.
if (subinfo /= INFO_DFT) then
    info = subinfo
    ! Arrange FHIST and XHIST so that they are in the chronological order.
    call rangehist(nf, xhist, fhist)
    ! Print a return message according to IPRINT.
    call retmsg(solver, info, iprint, nf, f, x)
    ! Postconditions
    if (DEBUGGING) then
        call assert(nf <= maxfun, 'NF <= MAXFUN', srname)
        call assert(size(x) == n .and. .not. any(is_nan(x)), 'SIZE(X) == N, X does not contain NaN', srname)
        call assert(.not. (is_nan(f) .or. is_posinf(f)), 'F is not NaN/+Inf', srname)
        call assert(size(xhist, 1) == n .and. size(xhist, 2) == maxxhist, 'SIZE(XHIST) == [N, MAXXHIST]', srname)
        call assert(.not. any(is_nan(xhist(:, 1:min(nf, maxxhist)))), 'XHIST does not contain NaN', srname)
        ! The last calculated X can be Inf (finite + finite can be Inf numerically).
        call assert(size(fhist) == maxfhist, 'SIZE(FHIST) == MAXFHIST', srname)
        call assert(.not. any(is_nan(fhist(1:min(nf, maxfhist))) .or. is_posinf(fhist(1:min(nf, maxfhist)))), &
            & 'FHIST does not contain NaN/+Inf', srname)
        call assert(.not. any(fhist(1:min(nf, maxfhist)) < f), 'F is the smallest in FHIST', srname)
    end if
    return
end if

! Initialize BMAT, ZMAT, and IDZ.
call inith(ij, xpt, idz, bmat, zmat)

! Initialize GQ, HQ, and PQ.
call initq(ij, fval, xpt, gq, hq, pq)

gopt = gq
if (kopt /= 1) then
    gopt = gopt + matprod(hq, xpt(:, kopt))
end if

! After initializing BMAT, ZMAT, GQ, HQ, PQ, one can also choose to return if these arrays contain
! NaN. We do not do it here. If such a model is harmful, then it will probably lead to other returns
! (NaN in X, NaN in F, trust-region subproblem fails, ...); otherwise, the code will continue to run
! and possibly recovers by geometry steps.

! Set some more initial values.
! We must initialize RATIO. Otherwise, when SHORTD = TRUE, compilers may raise a run-time error that
! RATIO is undefined. The value will not be used: when SHORTD = FALSE, its value will be overwritten;
! when SHORTD = TRUE, its value is used only in BAD_TRSTEP, which is TRUE regardless of RATIO.
! Similar for KNEW_TR.
! No need to initialize SHORTD unless MAXTR < 1, but some compilers may complain if we do not do it.
rho = rhobeg
delta = rho
shortd = .false.
ratio = -ONE
dnormsav = HUGENUM
moderrsav = HUGENUM
knew_tr = 0
knew_geo = 0
itest = 0

! MAXTR is the maximal number of trust-region iterations. Each trust-region iteration takes 1 or 2
! function evaluations unless the trust-region step is short or fails to reduce the trust-region
! model but the geometry step is not invoked. Thus the following MAXTR is unlikely to be reached.
maxtr = max(maxfun, 2_IK * maxfun)  ! MAX: precaution against overflow, which will make 2*MAXFUN < 0.
info = MAXTR_REACHED

! Begin the iterative procedure.
! After solving a trust-region subproblem, we use three boolean variables to control the workflow.
! SHORTD: Is the trust-region trial step too short to invoke a function evaluation?
! IMPROVE_GEO: Should we improve the geometry (Box 8 of Fig. 1 in the NEWUOA paper)?
! REDUCE_RHO: Should we reduce rho (Boxes 14 and 10 of Fig. 1 in the NEWUOA paper)?
! NEWUOA never sets IMPROVE_GEO and REDUCE_RHO to TRUE simultaneously.
do tr = 1, maxtr
    ! Generate the next trust region step D.
    !call trsapp(delta, gq, hq, pq, trtol, xopt, xpt, crvmin, d)
    call trsapp(delta, gopt, hq, pq, trtol, xopt, xpt, crvmin, d)
    dnorm = min(delta, norm(d))

    ! SHORTD corresponds to Box 3 of the NEWUOA paper. N.B.: we compare DNORM with RHO, not DELTA.
    shortd = (dnorm < HALF * rho)  ! HALF seems to work better than TENTH or QUART.

    ! Set QRED to the reduction of the quadratic model when the move D is made from XOPT. QRED
    ! should be positive. If it is nonpositive due to rounding errors, we will not take this step.
    !qred = -quadinc(d, xopt, xpt, gq, pq, hq)  ! QRED = Q(XOPT) - Q(XOPT + D)
    qred = -quadinc(d, xpt, gopt, pq, hq)

    if (shortd .or. .not. qred > 0) then
        ! In this case, do nothing but reducing DELTA. Afterward, DELTA < DNORM may occur.
        ! N.B.: 1. This value of DELTA will be discarded if REDUCE_RHO turns out TRUE later.
        ! 2. Without shrinking DELTA, the algorithm may be stuck in an infinite cycling, because
        ! both REDUCE_RHO and IMPROVE_GEO may end up with FALSE in this case.
        delta = TENTH * delta
        if (delta <= 1.5_RP * rho) then
            delta = rho  ! Set DELTA to RHO when it is close to or below.
        end if
    else
        ! Calculate the next value of the objective function.
        x = xbase + (xopt + d)
        call evaluate(calfun, x, f)
        nf = nf + 1_IK

        ! Print a message about the function evaluation according to IPRINT.
        call fmsg(solver, iprint, nf, f, x)
        ! Save X, F into the history.
        call savehist(nf, x, xhist, f, fhist)

        ! Check whether to exit
        subinfo = checkexit(maxfun, nf, f, ftarget, x)
        if (subinfo /= INFO_DFT) then
            info = subinfo
            exit
        end if

        ! Update DNORMSAV and MODERRSAV.
        ! DNORMSAV contains the DNORM of the latest 3 function evaluations with the current RHO.
        dnormsav = [dnormsav(2:size(dnormsav)), dnorm]
        ! MODERR is the error of the current model in predicting the change in F due to D.
        ! MODERRSAV is the prediction errors of the latest 3 models with the current RHO.
        moderr = f - fopt + qred
        moderrsav = [moderrsav(2:size(moderrsav)), moderr]

        ! Calculate the reduction ratio by REDRAT, which handles Inf/NaN carefully.
        ratio = redrat(fopt - f, qred, eta1)

        ! Update DELTA. After this, DELTA < DNORM may hold.
        delta = trrad(delta, dnorm, eta1, eta2, gamma1, gamma2, ratio)
        if (delta <= 1.5_RP * rho) then
            delta = rho  ! Set DELTA to RHO when it is close to or below.
        end if

        ! Is the newly generated X better than current best point?
        ximproved = (f < fopt)

        ! Set KNEW_TR to the index of the interpolation point to be replaced with XNEW = XOPT + D.
        ! KNEW_TR will ensure that the geometry of XPT is "good enough" after the replacement.
        ! N.B.:
        ! 1. KNEW_TR = 0 means it is impossible to obtain a good interpolation set by replacing any
        ! current interpolation point with XNEW. Then XNEW and its function value will be discarded.
        ! In this case, the geometry of XPT likely needs improvement, which will be handled below.
        ! 2. If XIMPROVED = TRUE (i.e., RATIO > 0), then SETDROP_TR should ensure KNEW_TR > 0 so that
        ! XNEW is included into XPT. Otherwise, SETDROP_TR is buggy. Moreover, if XIMPROVED = TRUE
        ! but KNEW_TR = 0, XOPT will differ from XPT(:, KOPT), because the former is set to XNEW but
        ! XNEW is discarded. Such a difference can lead to unexpected behaviors; for example,
        ! KNEW_GEO may equal KOPT, with which GEOSTEP will not work.
        knew_tr = setdrop_tr(idz, kopt, ximproved, bmat, d, delta, rho, xpt, zmat)

        ! Update [BMAT, ZMAT, IDZ] (represents H in the NEWUOA paper), [XPT, FVAL, KOPT, XOPT, FOPT]
        ! and [GQ, HQ, PQ] (the quadratic model), so that XPT(:, KNEW_TR) becomes XNEW = XOPT + D.
        ! If KNEW_TR = 0, the updating subroutines will do essentially nothing, as the algorithm
        ! decides not to include XNEW into XPT.
        if (knew_tr > 0) then
            xdrop = xpt(:, knew_tr)
            xosav = xopt
            call updateh(knew_tr, kopt, idz, d, xpt, bmat, zmat)
            call updatexf(knew_tr, ximproved, f, xopt + d, kopt, fval, xpt, fopt, xopt)
            !call updateq(idz, knew_tr, bmat, moderr, xdrop, zmat, gq, hq, pq)

            call updateq(idz, knew_tr, ximproved, bmat, d, moderr, xdrop, xosav, xpt, zmat, gopt, hq, pq)

            ! Test whether to replace the new quadratic model Q by the least-Frobenius norm
            ! interpolant Q_alt. Perform the replacement if certain criteria are satisfied.
            ! N.B.: 1. This part is OPTIONAL, but it is crucial for the performance on some
            ! problems. See Section 8 of the NEWUOA paper.
            ! 2. TRYQALT is called only after a trust-region step but not after a geometry step,
            ! maybe because the model is expected to be good after a geometry step.
            ! 3. If KNEW_TR = 0 after a trust-region step, TRYQALT is not invoked. In this case, the
            ! interpolation set is unchanged, so it seems reasonable to keep the model unchanged.
            ! 4. In theory, FVAL - FOPT in the call of TRYQALT can be changed to FVAL + C with any
            ! constant C. This constant will not affect the result in precise arithmetic. Powell
            ! chose C = - FVAL(KOPT_OLD), where KOPT_OLD is the KOPT before the update above (Powell
            ! updated KOPT after TRYQALT). Here we use C = -FOPT, as it worked slightly better on
            ! CUTEst, although there is no difference theoretically. Note that FVAL(KOPT_OLD) may
            ! not equal FOPT_OLD --- it may happen that KNEW_TR = KOPT_OLD so that FVAL(KOPT_OLD)
            ! has been revised after the last function evaluation.
            ! 5. Powell's code tries Q_alt only when DELT == RHO.
            !call tryqalt(idz, fval - fopt, ratio, bmat, zmat, itest, gq, hq, pq)
            call tryqalt(idz, bmat, fval - fopt, ratio, xopt, xpt, zmat, itest, gopt, hq, pq)
        end if
    end if  ! End of IF (SHORTD .OR. .NOT. QRED > 0). The normal trust-region calculation ends here.


    !----------------------------------------------------------------------------------------------!
    ! Before the next trust-region iteration, we may improve the geometry of XPT or reduce RHO
    ! according to IMPROVE_GEO and REDUCE_RHO, which in turn depend on the following indicators.
    ! N.B.: We must ensure that the algorithm does not set IMPROVE_GEO = TRUE at infinitely many
    ! consecutive iterations without moving XOPT or reducing RHO. Otherwise, the algorithm will get
    ! stuck in repetitive invocations of GEOSTEP. To this end, make sure the following.
    ! 1. The threshold for CLOSE_ITPSET is at least DELBAR, the trust region radius for GEOSTEP.
    ! Normally, DELBAR <= DELTA <= the threshold (In Powell's UOBYQA, DELBAR = RHO < the threshold).
    ! 2. If an iteration sets IMPROVE_GEO = TRUE, it must also reduce DELTA or set DELTA to RHO.

    ! ACCURATE_MOD: Are the recent models sufficiently accurate? Used only if SHORTD is TRUE.
    accurate_mod = all(abs(moderrsav) <= 0.125_RP * crvmin * rho**2) .and. all(dnormsav <= rho)
    ! CLOSE_ITPSET: Are the interpolation points close to XOPT?
    distsq = sum((xpt - spread(xopt, dim=2, ncopies=npt))**2, dim=1)
    !!MATLAB: distsq = sum((xpt - xopt).^2)  % xopt should be a column! Implicit expansion
    close_itpset = all(distsq <= 4.0_RP * delta**2)  ! Powell's original code.
    ! Below are some alternative definitions of CLOSE_ITPSET.
    ! !close_itpset = all(distsq <= delta**2)  ! This works poorly.
    ! !close_itpset = all(distsq <= 10.0_RP * delta**2)  ! Does not work as well as Powell's version.
    ! !close_itpset = all(distsq <= max((2.0_RP * delta)**2, (10.0_RP * rho)**2))  ! Powell's BOBYQA.
    ! ADEQUATE_GEO: Is the geometry of the interpolation set "adequate"?
    adequate_geo = (shortd .and. accurate_mod) .or. close_itpset
    ! SMALL_TRRAD: Is the trust-region radius small? This indicator seems not impactive in practice.
    ! When MAX(DELTA, DNORM) > RHO, as Powell mentioned under (2.3) of the NEWUOA paper, "RHO has
    ! not restricted the most recent choice of D", so it is not reasonable to reduce RHO.
    small_trrad = (max(delta, dnorm) <= rho)  ! Powell's code.
    !small_trrad = (delsav <= rho)  ! Behaves the same as Powell's version. DELSAV = unupdated DELTA.

    ! IMPROVE_GEO and REDUCE_RHO are defined as follows.

    ! BAD_TRSTEP (for IMPROVE_GEO): Is the last trust-region step bad?
    bad_trstep = (shortd .or. (.not. qred > 0) .or. ratio <= eta1 .or. knew_tr == 0)
    improve_geo = bad_trstep .and. .not. adequate_geo
    ! BAD_TRSTEP (for REDUCE_RHO): Is the last trust-region step bad?
    bad_trstep = (shortd .or. (.not. qred > 0) .or. ratio <= 0 .or. knew_tr == 0)
    reduce_rho = bad_trstep .and. adequate_geo .and. small_trrad

    ! Equivalently, REDUCE_RHO can be set as follows. It shows that REDUCE_RHO is TRUE in two cases.
    ! !bad_trstep = (shortd .or. (.not. qred > 0) .or. ratio <= 0 .or. knew_tr == 0)
    ! !reduce_rho = (shortd .and. accurate_mod) .or. (bad_trstep .and. close_itpset .and. small_trrad)

    ! With REDUCE_RHO properly defined, we can also set IMPROVE_GEO as follows.
    ! !bad_trstep = (shortd .or. (.not. qred > 0) .or. ratio <= eta1 .or. knew_tr == 0)
    ! !improve_geo = bad_trstep .and. (.not. reduce_rho) .and. (.not. close_itpset)

    ! With IMPROVE_GEO properly defined, we can also set REDUCE_RHO as follows.
    ! !bad_trstep = (shortd .or. (.not. qred > 0) .or. ratio <= 0 .or. knew_tr == 0)
    ! !reduce_rho = bad_trstep .and. (.not. improve_geo) .and. small_trrad

    ! NEWUOA never sets IMPROVE_GEO and REDUCE_RHO to TRUE simultaneously.
    !call assert(.not. (improve_geo .and. reduce_rho), 'IMPROVE_GEO and REDUCE_RHO are not both TRUE', srname)
    !
    ! If SHORTD is TRUE or QRED > 0 is FALSE, then either IMPROVE_GEO or REDUCE_RHO is TRUE unless
    ! CLOSE_ITPSET is TRUE but SMALL_TRRAD is FALSE.
    !call assert((.not. shortd .and. qred > 0) .or. (improve_geo .or. reduce_rho .or. &
    !    & (close_itpset .and. .not. small_trrad)), 'If SHORTD is TRUE or QRED > 0 is FALSE, then either&
    !    & IMPROVE_GEO or REDUCE_RHO is TRUE unless CLOSE_ITPSET is TRUE but SMALL_TRRAD is FALSE', srname)
    !----------------------------------------------------------------------------------------------!

    ! Comments on REDUCE_RHO:
    ! REDUCE_RHO corresponds to Boxes 14 and 10 of the NEWUOA paper.
    ! There are two case where REDUCE_RHO will be set to TRUE.
    ! Case 1. The trust-region step is short (SHORTD) and all the recent models are sufficiently
    ! accurate (ACCURATE_MOD), which corresponds to Box 14 of the NEWUOA paper. Why do we reduce RHO
    ! in this case? The reason is well explained by the BOBYQA paper around (6.9)--(6.10). Roughly
    ! speaking, in this case, a trust-region step is unlikely to decrease the objective function
    ! according to some estimations. This suggests that the current trust-region center may be an
    ! approximate local minimizer. When this occurs, the algorithm takes the view that the work for
    ! the current RHO is complete, and hence it will reduce RHO, which will enhance the resolution
    ! of the algorithm in general. The penultimate paragraph of Sec. 2 of the NEWUOA explains why
    ! this strategy is important to efficiency: without this strategy, each value of RHO typically
    ! consumes at least NPT - 1 function evaluations, which is laborious when NPT is (modestly) big.
    ! Case 2. All the interpolation points are close to XOPT (CLOSE_ITPSET) and the trust region is
    ! small (SMALL_TRRAD), but the trust-region step is "bad" (SHORTD is TRUE or RATIO is small). In
    ! this case, the algorithm decides that the work corresponding to the current RHO is complete,
    ! and hence it shrinks RHO (i.e., update the criterion for the "closeness" and SHORTD). Surely,
    ! one may ask whether this is the best choice --- it may happen that the trust-region step is
    ! bad because the trust-region model is poor. NEWUOA takes the view that, if XPT contains points
    ! far away from XOPT, the model can be substantially improved by replacing the farthest point
    ! with a nearby one produced by the geometry step; otherwise, it does not try the geometry step.
    ! N.B.:
    ! 0. If SHORTD is TRUE at the very first iteration, then REDUCE_RHO will be set to TRUE.
    ! 1. DELTA has been updated before arriving here: if SHORTD = TRUE, then DELTA was reduced by a
    ! factor of 10; otherwise, DELTA was updated after the trust-region iteration. DELTA < DNORM may
    ! hold due to the update of DELTA.
    ! 2. If SHORTD = FALSE and KNEW_TR > 0, then XPT has been updated after the trust-region
    ! iteration; if RATIO > 0 in addition, then XOPT has been updated as well.
    ! 3. If SHORTD = TRUE and REDUCE_RHO = TRUE, the trust-region step D does not invoke a function
    ! evaluation at the current iteration, but the same D will be generated again at the next
    ! iteration after RHO is reduced and DELTA is updated. See the end of Sec 2 of the NEWUOA paper.
    ! 4. If SHORTD = FALSE and KNEW_TR = 0, then the trust-region step invokes a function evaluation
    ! at XOPT + D, but [XOPT + D, F(XOPT +D)] is not included into [XPT, FVAL]. In other words, this
    ! function value is discarded.
    ! 5. If SHORTD = FALSE, KNEW_TR > 0 and RATIO <= TENTH, then [XPT, FVAL] is updated so that
    ! [XPT(KNEW_TR), FVAL(KNEW_TR)] = [XOPT + D, F(XOPT + D)], and the model is updated accordingly,
    ! but such a model will not be used in the next trust-region iteration, because a geometry step
    ! will be invoked to improve the geometry of the interpolation set and update the model again.
    ! 6. RATIO must be set even if SHORTD = TRUE. Otherwise, compilers will raise a run-time error.
    ! 7. We can move this setting of REDUCE_RHO downward below the definition of IMPROVE_GEO and
    ! change it to REDUCE_RHO = BAD_TRSTEP .AND. (.NOT. IMPROVE_GEO) .AND. (MAX(DELTA,DNORM) <= RHO)
    ! This definition can even be moved below IF (IMPROVE_GEO) ... END IF. Although DNORM gets a new
    ! value after the geometry step when IMPROVE_GEO = TRUE, this value does not affect REDUCE_RHO,
    ! because DNORM comes into play only if IMPROVE_GEO = FALSE.

    ! Comments on IMPROVE_GEO:
    ! IMPROVE_GEO corresponds to Box 8 of the NEWUOA paper.
    ! The geometry of XPT likely needs improvement if the trust-region step is bad (SHORTD or RATIO
    ! is small). As mentioned above, NEWUOA tries improving the geometry only if some points in XPT
    ! are far away from XOPT.  In addition, if the work for the current RHO is complete, then NEWUOA
    ! reduces RHO instead of improving the geometry of XPT. Particularly, if REDUCE_RHO is true
    ! according to Box 14 of the NEWUOA paper (D is short, and the recent models are sufficiently
    ! accurate), then "trying to improve the accuracy of the model would be a waste of effort"
    ! (see Powell's comment above (7.7) of the NEWUOA paper).

    ! Comments on BAD_TRSTEP:
    ! 0. KNEW_TR == 0 means that it is impossible to obtain a good XPT by replacing a current point
    ! with the one suggested by the trust-region step. According to SETDROP_TR, KNEW_TR is 0 only if
    ! RATIO <= 0. Therefore, we can remove KNEW_TR == 0 from the definitions of BAD_TRSTEP.
    ! Nevertheless, we keep it for robustness. Powell's code includes this condition as well.
    ! 1. Powell used different thresholds (0 and 0.1) for RATIO in the definitions of BAD_TRSTEP
    ! above. Unifying them to 0 makes little difference to the performance, sometimes worsening,
    ! sometimes improving, never substantially; unifying them to 0.1 makes little difference either.
    ! Update 20220204: In the current version, unifying the two thresholds to 0 seems to worsen
    ! the performance on noise-free CUTEst problems with at most 200 variables; unifying them to 0.1
    ! worsens it a bit as well.
    ! 2. Powell's code does not have (.NOT. QRED>0) in BAD_TRSTEP; it terminates if QRED > 0 fails.
    ! 3. Update 20221108: In UOBYQA, the definition of BAD_TRSTEP involves DDMOVE, which is the norm
    ! square of XPT_OLD(:, KNEW_TR) - XOPT_OLD, where XPT_OLD and XOPT_OLD are the XPT and XOPT
    ! before UPDATEXF is called. Roughly speaking, BAD_TRSTEP is set to FALSE if KNEW_TR > 0 and
    ! DDMOVE > 2*RHO. This is critical for the performance of UOBYQA. However, the same strategy
    ! does not improve the performance of NEWUOA/BOBYQA/LINCOA in a test on 20221108/9.


    ! Since IMPROVE_GEO and REDUCE_RHO are never TRUE simultaneously, the following two blocks are
    ! exchangeable: IF (IMPROVE_GEO) ... END IF and IF (REDUCE_RHO) ... END IF.

    ! Improve the geometry of the interpolation set by removing a point and adding a new one.
    if (improve_geo) then
        ! XPT(:, KNEW_GEO) will become XOPT + D below. KNEW_GEO /= KOPT unless there is a bug.
        knew_geo = int(maxloc(distsq, dim=1), kind(knew_geo))

        ! Set DELBAR, which will be used as the trust-region radius for the geometry-improving
        ! scheme GEOSTEP. Note that DELTA has been updated before arriving here. See the comments
        ! above the definition of IMPROVE_GEO.
        delbar = max(min(TENTH * sqrt(maxval(distsq)), HALF * delta), rho)

        ! Find D so that the geometry of XPT will be improved when XPT(:, KNEW_GEO) becomes XOPT + D.
        ! The GEOSTEP subroutine will call Powell's BIGLAG and BIGDEN.
        d = geostep(idz, knew_geo, kopt, bmat, delbar, xpt, zmat)

        ! Calculate the next value of the objective function.
        x = xbase + (xopt + d)
        call evaluate(calfun, x, f)
        nf = nf + 1_IK

        ! Print a message about the function evaluation according to IPRINT.
        call fmsg(solver, iprint, nf, f, x)
        ! Save X, F into the history.
        call savehist(nf, x, xhist, f, fhist)

        ! Check whether to exit
        subinfo = checkexit(maxfun, nf, f, ftarget, x)
        if (subinfo /= INFO_DFT) then
            info = subinfo
            exit
        end if

        ! Update DNORMSAV and MODERRSAV. (Should we?)
        ! DNORMSAV contains the DNORM of the latest 3 function evaluations with the current RHO.
        dnorm = min(delbar, norm(d))  ! In theory, DNORM = DELBAR in this case.
        dnormsav = [dnormsav(2:size(dnormsav)), dnorm]
        ! MODERR is the error of the current model in predicting the change in F due to D.
        ! MODERRSAV is the prediction errors of the latest 3 models with the current RHO.
        !moderr = f - fopt - quadinc(d, xopt, xpt, gq, pq, hq)  ! QUADINC = Q(XOPT + D) - Q(XOPT)

        moderr = f - fopt - quadinc(d, xpt, gopt, pq, hq)

        moderrsav = [moderrsav(2:size(moderrsav)), moderr]
        !------------------------------------------------------------------------------------------!
        ! Zaikun 20200801: Powell's code does not update DNORM. Therefore, DNORM is the length of
        ! the last trust-region trial step, which seems inconsistent with what is described in
        ! Section 7 (around (7.7)) of the NEWUOA paper. Seemingly we should keep DNORM = ||D||
        ! as we do here. The same problem exists in BOBYQA.
        !------------------------------------------------------------------------------------------!

        ! Is the newly generated X better than current best point?
        ximproved = (f < fopt)

        ! Update [BMAT, ZMAT, IDZ] (represents H in the NEWUOA paper), [XPT, FVAL, KOPT, XOPT, FOPT]
        ! and [GQ, HQ, PQ] (the quadratic model), so that XPT(:, KNEW_GEO) becomes XNEW = XOPT + D.
        xdrop = xpt(:, knew_geo)
        xosav = xopt
        call updateh(knew_geo, kopt, idz, d, xpt, bmat, zmat)
        call updatexf(knew_geo, ximproved, f, xopt + d, kopt, fval, xpt, fopt, xopt)
        !call updateq(idz, knew_geo, bmat, moderr, xdrop, zmat, gq, hq, pq)

        call updateq(idz, knew_geo, ximproved, bmat, d, moderr, xdrop, xosav, xpt, zmat, gopt, hq, pq)
    end if  ! End of IF (IMPROVE_GEO). The procedure of improving geometry ends.

    ! The calculations with the current RHO are complete. Enhance the resolution of the algorithm
    ! by reducing RHO; update DELTA at the same time.
    if (reduce_rho) then
        if (rho <= rhoend) then
            info = SMALL_TR_RADIUS
            exit
        end if
        delta = HALF * rho
        rho = redrho(rho, rhoend)
        delta = max(delta, rho)
        ! Print a message about the reduction of RHO according to IPRINT.
        call rhomsg(solver, iprint, nf, fopt, rho, xbase + xopt)
        ! DNORMSAV and MODERRSAV are corresponding to the latest 3 function evaluations with
        ! the current RHO. Update them after reducing RHO.
        dnormsav = HUGENUM
        moderrsav = HUGENUM
    end if  ! End of IF (REDUCE_RHO). The procedure of reducing RHO ends.

    ! Shift XBASE if XOPT may be too far from XBASE.
    ! Powell's original criteria for shifting XBASE is as follows.
    ! 1. After a trust region step that is not short, shift XBASE if SUM(XOPT**2) >= 1.0E3*DNORM**2.
    ! 2. Before a geometry step, shift XBASE if SUM(XOPT**2) >= 1.0E3*DELBAR**2.
    if (sum(xopt**2) >= 1.0E3_RP * delta**2) then
        !call shiftbase(xbase, xopt, xpt, zmat, bmat, pq, hq, idz, gq)
        call shiftbase(xbase, xopt, xpt, zmat, bmat, pq, hq, idz)
    end if
end do  ! End of DO TR = 1, MAXTR. The iterative procedure ends.

! Return, possibly after another Newton-Raphson step, if it is too short to have been tried before.
if (info == SMALL_TR_RADIUS .and. shortd .and. nf < maxfun) then
    x = xbase + (xopt + d)
    call evaluate(calfun, x, f)
    nf = nf + 1_IK
    ! Print a message about the function evaluation according to IPRINT.
    call fmsg(solver, iprint, nf, f, x)
    ! Save X, F into the history.
    call savehist(nf, x, xhist, f, fhist)
end if

! Choose the [X, F] to return: either the current [X, F] or [XBASE + XOPT, FOPT].
if (is_nan(f) .or. fopt < f) then
    x = xbase + xopt
    f = fopt
end if

! Arrange FHIST and XHIST so that they are in the chronological order.
call rangehist(nf, xhist, fhist)

! Print a return message according to IPRINT.
call retmsg(solver, info, iprint, nf, f, x)

!====================!
!  Calculation ends  !
!====================!

! Postconditions
if (DEBUGGING) then
    call assert(nf <= maxfun, 'NF <= MAXFUN', srname)
    call assert(size(x) == n .and. .not. any(is_nan(x)), 'SIZE(X) == N, X does not contain NaN', srname)
    call assert(.not. (is_nan(f) .or. is_posinf(f)), 'F is not NaN/+Inf', srname)
    call assert(size(xhist, 1) == n .and. size(xhist, 2) == maxxhist, 'SIZE(XHIST) == [N, MAXXHIST]', srname)
    call assert(.not. any(is_nan(xhist(:, 1:min(nf, maxxhist)))), 'XHIST does not contain NaN', srname)
    ! The last calculated X can be Inf (finite + finite can be Inf numerically).
    call assert(size(fhist) == maxfhist, 'SIZE(FHIST) == MAXFHIST', srname)
    call assert(.not. any(is_nan(fhist(1:min(nf, maxfhist))) .or. is_posinf(fhist(1:min(nf, maxfhist)))), &
        & 'FHIST does not contain NaN/+Inf', srname)
    call assert(.not. any(fhist(1:min(nf, maxfhist)) < f), 'F is the smallest in FHIST', srname)
end if

end subroutine newuob


subroutine updateq(idz, knew, ximproved, bmat, d, moderr, xdrop, xosav, xpt, zmat, gopt, hq, pq)
!--------------------------------------------------------------------------------------------------!
! This subroutine updates GOPT, HQ, and PQ when XPT(:, KNEW) changes from XDROP to XNEW = XOSAV + D,
! where XOSAV is the upupdated XOPT, namedly the XOPT before UPDATEXF is called.
! See Section 4 of the NEWUOA paper (there is no LINCOA paper).
! N.B.:
! XNEW is encoded in [BMAT, ZMAT, IDZ] after UPDATEH being called, and it also equals XPT(:, KNEW)
! after UPDATEXF being called. Indeed, we only need BMAT(:, KNEW) instead of the entire matrix.
!--------------------------------------------------------------------------------------------------!
! List of local arrays (including function-output arrays; likely to be stored on the stack): PQINC
!--------------------------------------------------------------------------------------------------!

! Generic modules
use, non_intrinsic :: consts_mod, only : RP, IK, ZERO, DEBUGGING
use, non_intrinsic :: debug_mod, only : assert
use, non_intrinsic :: infnan_mod, only : is_finite
use, non_intrinsic :: linalg_mod, only : r1update, issymmetric
use, non_intrinsic :: powalg_mod, only : omega_col, hess_mul

implicit none

! Inputs
integer(IK), intent(in) :: idz
integer(IK), intent(in) :: knew
logical, intent(in) :: ximproved
real(RP), intent(in) :: bmat(:, :) ! BMAT(N, NPT + N)
real(RP), intent(in) :: d(:) ! D(:)
real(RP), intent(in) :: moderr
real(RP), intent(in) :: xdrop(:)  ! XDROP(N)
real(RP), intent(in) :: xosav(:)  ! XOSAV(N)
real(RP), intent(in) :: xpt(:, :)  ! XPT(N, NPT)
real(RP), intent(in) :: zmat(:, :)  ! ZMAT(NPT, NPT - N - 1)

! In-outputs
real(RP), intent(inout) :: gopt(:)  ! GOPT(N)
real(RP), intent(inout) :: hq(:, :) ! HQ(N, N)
real(RP), intent(inout) :: pq(:)    ! PQ(NPT)

! Local variables
character(len=*), parameter :: srname = 'UPDATEQ'
integer(IK) :: n
integer(IK) :: npt
real(RP) :: pqinc(size(pq))

! Sizes
n = int(size(gopt), kind(n))
npt = int(size(pq), kind(npt))

! Preconditions
if (DEBUGGING) then
    call assert(n >= 1 .and. npt >= n + 2, 'N >= 1, NPT >= N + 2', srname)
    call assert(idz >= 1 .and. idz <= size(zmat, 2) + 1, '1 <= IDZ <= SIZE(ZMAT, 2) + 1', srname)
    call assert(knew >= 0 .and. knew <= npt, '0 <= KNEW <= NPT', srname)
    call assert(knew >= 1 .or. .not. ximproved, 'KNEW >= 1 unless X is not improved', srname)
    call assert(size(xdrop) == n .and. all(is_finite(xdrop)), 'SIZE(XDROP) == N, XDROP is finite', srname)
    call assert(size(xosav) == n .and. all(is_finite(xosav)), 'SIZE(XOSAV) == N, XOSAV is finite', srname)
    call assert(size(bmat, 1) == n .and. size(bmat, 2) == npt + n, 'SIZE(BMAT)==[N, NPT+N]', srname)
    call assert(issymmetric(bmat(:, npt + 1:npt + n)), 'BMAT(:, NPT+1:NPT+N) is symmetric', srname)
    call assert(size(zmat, 1) == npt .and. size(zmat, 2) == npt - n - 1, &
        & 'SIZE(ZMAT) == [NPT, NPT - N - 1]', srname)
    call assert(all(is_finite(xpt)), 'XPT is finite', srname)
    call assert(size(hq, 1) == n .and. issymmetric(hq), 'HQ is an NxN symmetric matrix', srname)
end if

!====================!
! Calculation starts !
!====================!

! Do nothing when KNEW is 0. This can only happen after a trust-region step.
if (knew <= 0) then  ! KNEW < 0 is impossible if the input is correct.
    return
end if

! The unupdated model corresponding to [GOPT, HQ, PQ] interpolates F at all points in XPT except for
! XNEW. The error is MODERR = [F(XNEW)-F(XOPT)] - [Q(XNEW)-Q(XOPT)].

! Absorb PQ(KNEW)*XDROP*XDROP^T into the explicit part of the Hessian.
! Implement R1UPDATE properly so that it ensures that HQ is symmetric.
call r1update(hq, pq(knew), xdrop)
pq(knew) = ZERO

! Update the implicit part of the Hessian.
pqinc = moderr * omega_col(idz, zmat, knew)
pq = pq + pqinc

! Update the gradient, which needs the updated XPT.
gopt = gopt + moderr * bmat(:, knew) + hess_mul(xosav, xpt, pqinc)

! Further update GOPT if XIMPROVED is TRUE, as XOPT changes from XOSAV to XNEW = XOSAV + D.
if (ximproved) then
    gopt = gopt + hess_mul(d, xpt, pq, hq)
end if

!====================!
!  Calculation ends  !
!====================!

! Postconditions
if (DEBUGGING) then
    call assert(size(gopt) == n, 'SIZE(GOPT) = N', srname)
    call assert(size(hq, 1) == n .and. issymmetric(hq), 'HQ is an NxN symmetric matrix', srname)
    call assert(size(pq) == npt, 'SIZE(PQ) = NPT', srname)
end if

end subroutine updateq

subroutine tryqalt(idz, bmat, fval, ratio, xopt, xpt, zmat, itest, gopt, hq, pq)
!--------------------------------------------------------------------------------------------------!
! This subroutine tests whether to replace Q by the alternative model, namely the model that
! minimizes the F-norm of the Hessian subject to the interpolation conditions. It does the
! replacement if certain criteria are met (i.e., when ITEST = 3). See the paragraph around (6.12) of
! the BOBYQA paper.
!--------------------------------------------------------------------------------------------------!

! Generic modules
use, non_intrinsic :: consts_mod, only : RP, IK, ZERO, TEN, TENTH, DEBUGGING
use, non_intrinsic :: debug_mod, only : assert
use, non_intrinsic :: infnan_mod, only : is_nan, is_posinf
use, non_intrinsic :: linalg_mod, only : matprod, inprod, issymmetric, trueloc
use, non_intrinsic :: powalg_mod, only : hess_mul, omega_mul

implicit none

! Inputs
integer(IK), intent(in) :: idz
real(RP), intent(in) :: bmat(:, :)  ! BMAT(N, NPT+N)
real(RP), intent(in) :: fval(:)     ! FVAL(NPT)
real(RP), intent(in) :: ratio
!real(RP), intent(in) :: sl(:)       ! SL(N)
!real(RP), intent(in) :: su(:)       ! SU(N)
real(RP), intent(in) :: xopt(:)     ! XOPT(N)
real(RP), intent(in) :: xpt(:, :)   ! XOPT(N, NPT)
real(RP), intent(in) :: zmat(:, :)  ! ZMAT(NPT, NPT-N-1)

! In-output
integer(IK), intent(inout) :: itest
real(RP), intent(inout) :: gopt(:)    ! GOPT(N)
real(RP), intent(inout) :: hq(:, :) ! HQ(N, N)
real(RP), intent(inout) :: pq(:)    ! PQ(NPT)
! N.B.:
! GOPT, HQ, and PQ should be INTENT(INOUT) instead of INTENT(OUT). According to the Fortran 2018
! standard, an INTENT(OUT) dummy argument becomes undefined on invocation of the procedure.
! Therefore, if the procedure does not define such an argument, its value becomes undefined,
! which is the case for HQ and PQ when ITEST < 3 at exit. In addition, the information in GOPT is
! needed for definining ITEST, so it must be INTENT(INOUT).

! Local variables
character(len=*), parameter :: srname = 'TRYQALT'
integer(IK) :: n
integer(IK) :: npt
real(RP) :: galt(size(gopt))
real(RP) :: gisq
real(RP) :: gqsq
real(RP) :: pgalt(size(gopt))
real(RP) :: pgopt(size(gopt))
real(RP) :: pqalt(size(pq))

! Debugging variables
!real(RP) :: intp_tol

! Sizes
n = int(size(gopt), kind(n))
npt = int(size(pq), kind(npt))

! Preconditions
if (DEBUGGING) then
    call assert(n >= 1 .and. npt >= n + 2, 'N >= 1, NPT >= N + 2', srname)
    ! By the definition of RATIO in ratio.f90, RATIO cannot be NaN unless the actual reduction is
    ! NaN, which should NOT happen due to the moderated extreme barrier.
    call assert(.not. is_nan(ratio), 'RATIO is not NaN', srname)
    call assert(size(fval) == npt .and. .not. any(is_nan(fval) .or. is_posinf(fval)), &
        & 'SIZE(FVAL) == NPT and FVAL is not NaN or +Inf', srname)
    call assert(size(bmat, 1) == n .and. size(bmat, 2) == npt + n, 'SIZE(BMAT)==[N, NPT+N]', srname)
    call assert(issymmetric(bmat(:, npt + 1:npt + n)), 'BMAT(:, NPT+1:NPT+N) is symmetric', srname)
    call assert(size(zmat, 1) == npt .and. size(zmat, 2) == npt - n - 1, &
        & 'SIZE(ZMAT) == [NPT, NPT - N - 1]', srname)
    call assert(size(gopt) == n, 'SIZE(GOPT) = N', srname)
    call assert(size(hq, 1) == n .and. issymmetric(hq), 'HQ is an NxN symmetric matrix', srname)
    call assert(size(pq) == npt, 'SIZE(PQ) = NPT', srname)
    ! [GOPT, HQ, PQ] cannot pass the following test if FVAL contains extremely large values.
    !intp_tol = max(1.0E-8_RP, min(1.0E-1_RP, 1.0E10_RP * real(size(pq), RP) * EPS))
    !call wassert(errquad(fval, xpt, gopt, pq, hq) <= intp_tol, 'Q interpolates FVAL at XPT', srname)
end if

!====================!
! Calculation starts !
!====================!

! Calculate the norm square of the projected gradient.
pgopt = gopt
!pgopt(trueloc(xopt >= su)) = max(ZERO, gopt(trueloc(xopt >= su)))
!pgopt(trueloc(xopt <= sl)) = min(ZERO, gopt(trueloc(xopt <= sl)))
gqsq = sum(pgopt**2)

! Calculate the parameters of the least Frobenius norm interpolant to the current data.
pqalt = omega_mul(idz, zmat, fval)
galt = matprod(bmat(:, 1:npt), fval) + hess_mul(xopt, xpt, pqalt)

! Calculate the norm square of the projected alternative gradient.
pgalt = galt
!pgalt(trueloc(xopt >= su)) = max(ZERO, galt(trueloc(xopt >= su)))
!pgalt(trueloc(xopt <= sl)) = min(ZERO, galt(trueloc(xopt <= sl)))
gisq = sum(pgalt**2)

! Test whether to replace the new quadratic model by the least Frobenius norm interpolant,
! making the replacement if the test is satisfied.
! N.B.: In the following IF, Powell's condition is GQSQ < TEN *GISQ. The condition here is adopted
! and adapted from NEWUOA, and it seems to improve the performance.
!if (ratio > TENTH .or. inprod(gopt, gopt)< TEN * inprod(galt, galt)) then  ! BOBYQA
if (ratio > TENTH .or. inprod(gopt, gopt) < 1.0E2_RP * inprod(galt, galt)) then  ! NEWUOA
    itest = 0
else
    itest = itest + 1_IK
end if
if (itest >= 3) then
    gopt = galt
    pq = pqalt
    hq = ZERO
    itest = 0
end if

!====================!
!  Calculation ends  !
!====================!

! Postconditions
if (DEBUGGING) then
    call assert(size(gopt) == n, 'SIZE(GOPT) = N', srname)
    call assert(size(hq, 1) == n .and. issymmetric(hq), 'HQ is an NxN symmetric matrix', srname)
    call assert(size(pq) == npt, 'SIZE(PQ) = NPT', srname)
    ! [GOPT, HQ, PQ] cannot pass the following test if FVAL contains extremely large values.
    !call wassert(errquad(fval, xpt, gopt, pq, hq) <= intp_tol, 'QALT interpolates FVAL at XPT', srname)
end if

end subroutine tryqalt


end module newuob_mod
