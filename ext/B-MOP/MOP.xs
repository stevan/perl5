/*      MOP.xs
 *
 *      Copyright (c) 2026 Stevan Little
 *
 *      You may distribute under the terms of either the GNU General Public
 *      License or the Artistic License, as specified in the README file.
 *
 *      Read-only MOP introspection for the core class feature.
 *      Wraps the internal C structs (xpvhv_aux, padname_fieldinfo, CV)
 *      as lightweight blessed objects, following the B.xs pattern.
 */

#define PERL_NO_GET_CONTEXT
#define PERL_EXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/* These macros are #undef'd in embed.h for non-PERL_CORE builds,
 * but we need them for role introspection. Re-define them here. */
#ifndef HvAUXf_IS_ROLE
#  define HvAUXf_IS_ROLE 0x8
#endif
#ifndef HvSTASH_IS_ROLE
#  define HvSTASH_IS_ROLE(hv) \
    (HvHasAUX(hv) && HvAUX(hv)->xhv_aux_flags & HvAUXf_IS_ROLE)
#endif
#ifndef HvSTASH_IS_CLASS_OR_ROLE
#  define HvSTASH_IS_CLASS_OR_ROLE(hv) \
    (HvHasAUX(hv) && HvAUX(hv)->xhv_aux_flags & (HvAUXf_IS_CLASS | HvAUXf_IS_ROLE))
#endif

/* Pointer typedefs — XS maps B__MOP__Class to B::MOP::Class etc. */
typedef HV      *B__MOP__Class;
typedef HV      *B__MOP__Role;
typedef PADNAME *B__MOP__Field;
typedef CV      *B__MOP__Method;

/* Helper: wrap an HV* class stash as a B::MOP::Class */
static SV *
make_class_object(pTHX_ HV *stash)
{
    SV *obj = sv_newmortal();
    sv_setiv(newSVrv(obj, "B::MOP::Class"), PTR2IV(stash));
    return obj;
}

/* Helper: wrap a PADNAME* field as a B::MOP::Field */
static SV *
make_field_object(pTHX_ PADNAME *pn)
{
    SV *obj = sv_newmortal();
    sv_setiv(newSVrv(obj, "B::MOP::Field"), PTR2IV(pn));
    return obj;
}

/* Helper: wrap an HV* role stash as a B::MOP::Role */
static SV *
make_role_object(pTHX_ HV *stash)
{
    SV *obj = sv_newmortal();
    sv_setiv(newSVrv(obj, "B::MOP::Role"), PTR2IV(stash));
    return obj;
}

/* Helper: wrap a CV* method as a B::MOP::Method */
static SV *
make_method_object(pTHX_ CV *cv)
{
    SV *obj = sv_newmortal();
    sv_setiv(newSVrv(obj, "B::MOP::Method"), PTR2IV(cv));
    return obj;
}

MODULE = B::MOP    PACKAGE = B::MOP

void
for_class(pkg, name_or_obj)
    SV *pkg
    SV *name_or_obj
PPCODE:
{
    HV *stash;

    PERL_UNUSED_VAR(pkg);

    if (SvROK(name_or_obj) && SvOBJECT(SvRV(name_or_obj))) {
        /* B::MOP->for_class($obj) — extract stash from blessed ref */
        stash = SvSTASH(SvRV(name_or_obj));
    }
    else {
        /* B::MOP->for_class('ClassName') — look up stash by name */
        stash = gv_stashsv(name_or_obj, 0);
    }

    if (!stash)
        croak("No such class '%" SVf "'", SVfARG(name_or_obj));

    if (!HvSTASH_IS_CLASS(stash))
        croak("'%" SVf "' is not a class", SVfARG(name_or_obj));

    PUSHs(make_class_object(aTHX_ stash));
}

void
for_role(pkg, name_sv)
    SV *pkg
    SV *name_sv
PPCODE:
{
    HV *stash;

    PERL_UNUSED_VAR(pkg);

    stash = gv_stashsv(name_sv, 0);

    if (!stash)
        croak("No such role '%" SVf "'", SVfARG(name_sv));

    if (!HvSTASH_IS_ROLE(stash))
        croak("'%" SVf "' is not a role", SVfARG(name_sv));

    PUSHs(make_role_object(aTHX_ stash));
}

MODULE = B::MOP    PACKAGE = B::MOP::Class

SV *
name(self)
    B::MOP::Class self
CODE:
    RETVAL = newSVhek(HvNAME_HEK(self));
OUTPUT:
    RETVAL

void
superclass(self)
    B::MOP::Class self
PPCODE:
{
    struct xpvhv_aux *aux = HvAUX(self);
    if (aux->xhv_class_superclass)
        PUSHs(make_class_object(aTHX_ aux->xhv_class_superclass));
    else
        PUSHs(&PL_sv_undef);
}

void
fields(self)
    B::MOP::Class self
PPCODE:
{
    struct xpvhv_aux *aux = HvAUX(self);
    PADNAMELIST *fieldnames = aux->xhv_class_fields;
    if (fieldnames) {
        PADNAME **pnp = PadnamelistARRAY(fieldnames);
        SSize_t i, max = PadnamelistMAX(fieldnames);
        for (i = 0; i <= max; i++) {
            PADNAME *pn = pnp[i];
            if (pn && PadnameIsFIELD(pn))
                PUSHs(make_field_object(aTHX_ pn));
        }
    }
}

void
methods(self)
    B::MOP::Class self
PPCODE:
{
    HE *he;
    (void)hv_iterinit(self);
    while ((he = hv_iternext(self))) {
        SV *val = HeVAL(he);
        CV *cv = NULL;
        if (!val)
            continue;
        if (SvTYPE(val) == SVt_PVGV && isGV_with_GP(val)) {
            /* Full GV entry — extract the CV */
            cv = GvCV((GV *)val);
        }
        else if (SvROK(val) && SvTYPE(SvRV(val)) == SVt_PVCV) {
            /* Stash entry is an RV to a CV (stub optimization) */
            cv = (CV *)SvRV(val);
        }
        if (cv && CvIsMETHOD(cv)) {
            PUSHs(make_method_object(aTHX_ cv));
        }
    }
}

void
adjust_blocks(self)
    B::MOP::Class self
PPCODE:
{
    struct xpvhv_aux *aux = HvAUX(self);
    AV *adjusts = aux->xhv_class_adjust_blocks;
    if (adjusts) {
        SSize_t i, max = av_count(adjusts);
        for (i = 0; i < max; i++) {
            SV **svp = av_fetch(adjusts, i, 0);
            if (svp && *svp) {
                /* Return as B::CV — bless the pointer directly */
                SV *obj = sv_newmortal();
                sv_setiv(newSVrv(obj, "B::CV"), PTR2IV(*svp));
                PUSHs(obj);
            }
        }
    }
}

void
roles(self)
    B::MOP::Class self
PPCODE:
{
    struct xpvhv_aux *aux = HvAUX(self);
    AV *roles = aux->xhv_class_roles;
    if (roles) {
        SSize_t i, max = av_count(roles);
        for (i = 0; i < max; i++) {
            SV **svp = av_fetch(roles, i, 0);
            if (svp && *svp) {
                HV *role_stash = (HV *)*svp;
                PUSHs(make_role_object(aTHX_ role_stash));
            }
        }
    }
}

void
stash(self)
    B::MOP::Class self
PPCODE:
{
    SV *obj = sv_newmortal();
    sv_setiv(newSVrv(obj, "B::HV"), PTR2IV(self));
    PUSHs(obj);
}

MODULE = B::MOP    PACKAGE = B::MOP::Field

SV *
name(self)
    B::MOP::Field self
CODE:
    RETVAL = newSVpvn_flags(PadnamePV(self), PadnameLEN(self), SVf_UTF8);
OUTPUT:
    RETVAL

SV *
sigil(self)
    B::MOP::Field self
CODE:
    RETVAL = newSVpvn(PadnamePV(self), 1);
OUTPUT:
    RETVAL

PADOFFSET
fieldix(self)
    B::MOP::Field self
CODE:
    RETVAL = PadnameFIELDINFO(self)->fieldix;
OUTPUT:
    RETVAL

void
class(self)
    B::MOP::Field self
PPCODE:
{
    HV *stash = PadnameFIELDINFO(self)->fieldstash;
    if (stash && HvSTASH_IS_ROLE(stash))
        PUSHs(make_role_object(aTHX_ stash));
    else
        PUSHs(make_class_object(aTHX_ stash));
}

void
param_name(self)
    B::MOP::Field self
PPCODE:
{
    SV *paramname = PadnameFIELDINFO(self)->paramname;
    if (paramname)
        PUSHs(sv_2mortal(newSVsv(paramname)));
    else
        PUSHs(&PL_sv_undef);
}

bool
has_default(self)
    B::MOP::Field self
CODE:
    RETVAL = cBOOL(PadnameFIELDINFO(self)->defop);
OUTPUT:
    RETVAL

MODULE = B::MOP    PACKAGE = B::MOP::Method

SV *
name(self)
    B::MOP::Method self
CODE:
    if (CvNAMED(self))
        RETVAL = newSVhek(CvNAME_HEK(self));
    else if (CvGV(self))
        RETVAL = newSVpv(GvNAME(CvGV(self)), 0);
    else
        RETVAL = &PL_sv_undef;
OUTPUT:
    RETVAL

void
class(self)
    B::MOP::Method self
PPCODE:
{
    HV *stash = CvSTASH(self);
    if (stash && HvSTASH_IS_ROLE(stash))
        PUSHs(make_role_object(aTHX_ stash));
    else if (stash && HvSTASH_IS_CLASS(stash))
        PUSHs(make_class_object(aTHX_ stash));
    else
        PUSHs(&PL_sv_undef);
}

void
cv(self)
    B::MOP::Method self
PPCODE:
{
    SV *obj = sv_newmortal();
    sv_setiv(newSVrv(obj, "B::CV"), PTR2IV(self));
    PUSHs(obj);
}

MODULE = B::MOP    PACKAGE = B::MOP::Role

SV *
name(self)
    B::MOP::Role self
CODE:
    RETVAL = newSVhek(HvNAME_HEK(self));
OUTPUT:
    RETVAL

void
fields(self)
    B::MOP::Role self
PPCODE:
{
    struct xpvhv_aux *aux = HvAUX(self);
    PADNAMELIST *fieldnames = aux->xhv_class_fields;
    if (fieldnames) {
        PADNAME **pnp = PadnamelistARRAY(fieldnames);
        SSize_t i, max = PadnamelistMAX(fieldnames);
        for (i = 0; i <= max; i++) {
            PADNAME *pn = pnp[i];
            if (pn && PadnameIsFIELD(pn))
                PUSHs(make_field_object(aTHX_ pn));
        }
    }
}

void
methods(self)
    B::MOP::Role self
PPCODE:
{
    HE *he;
    (void)hv_iterinit(self);
    while ((he = hv_iternext(self))) {
        SV *val = HeVAL(he);
        CV *cv = NULL;
        if (!val)
            continue;
        if (SvTYPE(val) == SVt_PVGV && isGV_with_GP(val)) {
            cv = GvCV((GV *)val);
        }
        else if (SvROK(val) && SvTYPE(SvRV(val)) == SVt_PVCV) {
            cv = (CV *)SvRV(val);
        }
        if (cv && CvIsMETHOD(cv)) {
            PUSHs(make_method_object(aTHX_ cv));
        }
    }
}

void
roles(self)
    B::MOP::Role self
PPCODE:
{
    struct xpvhv_aux *aux = HvAUX(self);
    AV *roles = aux->xhv_class_roles;
    if (roles) {
        SSize_t i, max = av_count(roles);
        for (i = 0; i < max; i++) {
            SV **svp = av_fetch(roles, i, 0);
            if (svp && *svp) {
                HV *role_stash = (HV *)*svp;
                PUSHs(make_role_object(aTHX_ role_stash));
            }
        }
    }
}

void
adjust_blocks(self)
    B::MOP::Role self
PPCODE:
{
    struct xpvhv_aux *aux = HvAUX(self);
    AV *adjusts = aux->xhv_class_adjust_blocks;
    if (adjusts) {
        SSize_t i, max = av_count(adjusts);
        for (i = 0; i < max; i++) {
            SV **svp = av_fetch(adjusts, i, 0);
            if (svp && *svp) {
                SV *obj = sv_newmortal();
                sv_setiv(newSVrv(obj, "B::CV"), PTR2IV(*svp));
                PUSHs(obj);
            }
        }
    }
}

void
stash(self)
    B::MOP::Role self
PPCODE:
{
    SV *obj = sv_newmortal();
    sv_setiv(newSVrv(obj, "B::HV"), PTR2IV(self));
    PUSHs(obj);
}

void
required_methods(self)
    B::MOP::Role self
PPCODE:
{
    HE *he;
    (void)hv_iterinit(self);
    while ((he = hv_iternext(self))) {
        SV *val = HeVAL(he);
        CV *cv = NULL;
        if (!val)
            continue;
        if (SvTYPE(val) == SVt_PVGV && isGV_with_GP(val)) {
            cv = GvCV((GV *)val);
        }
        else if (SvROK(val) && SvTYPE(SvRV(val)) == SVt_PVCV) {
            cv = (CV *)SvRV(val);
        }
        if (cv && CvIsMETHOD(cv) && !CvROOT(cv) && !CvXSUB(cv)) {
            SV *name;
            if (CvNAMED(cv))
                name = newSVhek(CvNAME_HEK(cv));
            else if (CvGV(cv))
                name = newSVpv(GvNAME(CvGV(cv)), 0);
            else
                continue;
            PUSHs(sv_2mortal(name));
        }
    }
}
