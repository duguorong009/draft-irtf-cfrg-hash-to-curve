#!/usr/bin/sage
# vim: syntax=python

from collections import namedtuple
import sys

from hash_to_field import hash_to_field, expand_message_xof

try:
    from sagelib.curves import EdwardsCurve, MontgomeryCurve
    from sagelib.ell2_generic import GenericEll2
except ImportError:
    sys.exit("Error loading preprocessed sage files. Try running `make clean pyfiles`")

BasicH2CSuiteDef = namedtuple("BasicH2CSuiteDef", "E F Aa Bd sgn0 expand H L MapT h_eff k is_ro dst")
IsoH2CSuiteDef = namedtuple("IsoH2CSuiteDef", "base Ap Bp iso_map")
EdwH2CSuiteDef = namedtuple("EdwH2CSuiteDef", "base Ap Bp rational_map")

class BasicH2CSuite(object):
    vector = None

    def __init__(self, name, sdef):
        assert isinstance(sdef, BasicH2CSuiteDef)

        # basics: details of the base field
        F = sdef.F
        self.suite_name = name
        self.curve_name = sdef.E
        self.F = F
        self.p = F.characteristic()
        self.m = F.degree()

        # set up the map-to-curve instance
        self.m2c = sdef.MapT(F, sdef.Aa, sdef.Bd)
        self.m2c.set_sgn0(sdef.sgn0)

        # precompute vector basis for field, used by hash_to_field
        self.field_gens = tuple( F.gen()^k for k in range(0, self.m) )

        # save other params
        self.expand = sdef.expand
        self.H = sdef.H
        self.L = sdef.L
        self.h_eff = sdef.h_eff
        self.k = sdef.k
        self.is_ro = sdef.is_ro
        self.dst = sdef.dst

    def __dict__(self):
        return {
            "ciphersuite": self.suite_name,
            "field":{
                "p" :  '0x{0}'.format(ZZ(self.p).hex()),
                "m" :  '0x{0}'.format(ZZ(self.m).hex()),
            },
            "curve": self.curve_name,
            "dst": self.dst,
            "hash": (self.H()).name,
            "map": self.m2c.__dict__(),
            "k": '0x{0}'.format(ZZ(self.k).hex()),
            "expand": "XOF" if self.expand == expand_message_xof else "XMD",
            "randomOracle": bool(self.is_ro),
        }

    @staticmethod
    def to_self(x):
        # in descendents, overridden to convert points from map_to_curve repr to output repr
        return x

    def __call__(self, msg, output_test_vector=False):
        self.vector = {}
        self.vector["msg"] = msg
        self.vector["P"] = self.hash(msg)
        if output_test_vector:
            return self.vector
        return self.vector["P"]

    def hash_to_field(self, msg, count):
        xi_vals = hash_to_field(msg, count, self.dst, self.p, self.m, self.L, self.expand, self.H, self.k)
        return [ sum( a * b for (a, b) in zip(xi, self.field_gens) ) for xi in xi_vals ]

    def map_to_curve(self, u):
        return self.to_self(self.m2c.map_to_curve(u))

    def clear_cofactor(self, P):
        return P * self.h_eff

    def encode_to_curve(self, msg):
        u = self.hash_to_field(msg, 1)
        Q = self.map_to_curve(u[0])
        P = self.clear_cofactor(Q)
        return P

    def hash_to_curve(self, msg):
        u = self.hash_to_field(msg, 2)
        Q0 = self.map_to_curve(u[0])
        Q1 = self.map_to_curve(u[1])
        R = Q0 + Q1
        P = self.clear_cofactor(R)
        return P

    # in descendents, test direct vs indirect hash to curve
    def hash(self, msg):
        if self.is_ro:
            res = self.hash_to_curve(msg)
        else:
            res = self.encode_to_curve(msg)
        return res

class IsoH2CSuite(BasicH2CSuite):
    def __init__(self, name, sdef):
        assert isinstance(sdef, IsoH2CSuiteDef)
        assert isinstance(sdef.base, BasicH2CSuiteDef)
        super(IsoH2CSuite, self).__init__(name, sdef.base._replace(Aa=sdef.Ap, Bd=sdef.Bp))

        # check that we got a reasonable isogeny map
        self.iso_map = sdef.iso_map
        assert self.iso_map.domain() == EllipticCurve(self.F, [sdef.Ap, sdef.Bp]), "isogeny map domain mismatch"
        assert self.iso_map.codomain() == EllipticCurve(self.F, [sdef.base.Aa, sdef.base.Bd]), "isogeny map codomain mismatch"
        self.to_self = self.iso_map

class MontyH2CSuite(BasicH2CSuite):
    def __init__(self, name, sdef):
        assert isinstance(sdef, BasicH2CSuiteDef)

        # figure out mapping to required Weierstrass form and init base class
        super(MontyH2CSuite, self).__init__(name, sdef._replace(MapT=GenericEll2))

        # helper: do point ops directly on the Monty repr
        self.monty = MontgomeryCurve(sdef.F, sdef.Aa, sdef.Bd)
        self.to_self = self.monty.to_self

class EdwH2CSuite(MontyH2CSuite):
    def __init__(self, name, sdef):
        assert isinstance(sdef, EdwH2CSuiteDef)
        super(EdwH2CSuite, self).__init__(name, sdef.base._replace(Aa=sdef.Ap, Bd=sdef.Bp))

        # helper: do 'native' point ops directly on the Edwards repr
        self.edwards = EdwardsCurve(sdef.base.F, sdef.base.Aa, sdef.base.Bd)
        self.rational_map = sdef.rational_map
        self.to_self = lambda P: self.edwards(*sdef.rational_map(self.monty.to_self(P)))
