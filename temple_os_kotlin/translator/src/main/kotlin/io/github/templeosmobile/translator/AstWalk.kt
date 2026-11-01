package io.github.templeosmobile.translator

import io.github.templeosmobile.core.holyc.*

/** Pre-order traversal of statements and expressions (defaults of called functions are not visited). */
open class AstWalk {
    open fun stmt(s: Stmt) {
        when (s) {
            is Block -> s.list.forEach { stmt(it) }
            is ExprStmt -> expr(s.e)
            is If -> { expr(s.c); stmt(s.t); s.f?.let { stmt(it) } }
            is While -> { expr(s.c); stmt(s.body) }
            is DoWhile -> { stmt(s.body); expr(s.c) }
            is For -> { s.init?.let { stmt(it) }; s.c?.let { expr(it) }; s.step?.let { expr(it) }; stmt(s.body) }
            is Switch -> { expr(s.e); s.body.forEach { stmt(it) } }
            is Return -> s.e?.let { expr(it) }
            is Try -> { stmt(s.body); stmt(s.handler) }
            is LocalInit -> s.init?.let { init(it) }
            is GlobalInit -> init(s.init)
            else -> {}
        }
    }

    open fun init(i: Init) {
        when (i) {
            is ExprInit -> expr(i.e)
            is ListInit -> i.items.forEach { init(it) }
        }
    }

    open fun expr(e: Expr) {
        when (e) {
            is Unary -> expr(e.e)
            is Binary -> { expr(e.l); expr(e.r) }
            is Chain -> e.xs.forEach { expr(it) }
            is Logical -> { expr(e.l); expr(e.r) }
            is Assign -> { expr(e.target); expr(e.value) }
            is IncDec -> expr(e.target)
            is Call -> { e.callee?.let { expr(it) }; e.args.forEach { it?.let { a -> expr(a) } } }
            is Index -> { expr(e.base); expr(e.idx) }
            is MemberAccess -> expr(e.base)
            is Deref -> expr(e.e)
            is AddrOf -> expr(e.e)
            is Cast -> expr(e.e)
            is Comma -> e.xs.forEach { expr(it) }
            else -> {}
        }
    }
}
