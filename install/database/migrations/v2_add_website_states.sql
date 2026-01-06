CREATE TABLE IF NOT EXISTS `checked_websites` (
    `ID` BIGINT NOT NULL AUTO_INCREMENT,
    `name` TEXT NOT NULL,
    `state` TEXT NOT NULL,
    `isDownMessageHasBeenSent` TINYINT NOT NULL DEFAULT '0',
    PRIMARY KEY (`ID`)
) ENGINE=InnoDB;

INSERT INTO schema_migrations (migration)
SELECT 'V2__add_website_states'
WHERE NOT EXISTS (
    SELECT 1 FROM schema_migrations WHERE migration = 'V2__add_website_states'
);