from db import DB_LOCK, db_fetchall


def rows(query, args=()):
    with DB_LOCK:
        return [dict(row) for row in db_fetchall(query, args)]


def summary():
    return {
         "nodes": rows("select * from health order by node"),
         "users": rows("""
            select node, "user" as user, uplink, downlink, uplink + downlink as total,
                   online, active, last_seen, last_online
            from totals
            order by total desc, node, "user"
         """),
     }
