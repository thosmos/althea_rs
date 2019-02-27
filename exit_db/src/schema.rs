table! {
    clients (mesh_ip) {
        mesh_ip -> Varchar,
        wg_pubkey -> Varchar,
        wg_port -> Int4,
        internal_ip -> Varchar,
        eth_address -> Varchar,
        email -> Varchar,
        phone -> Varchar,
        country -> Varchar,
        email_code -> Varchar,
        verified -> Bool,
        email_sent_time -> Int8,
        text_sent -> Bool,
        last_seen -> Int8,
    }
}
