package org.l2jmobius.gameserver.util.argsparse;

import java.util.Arrays;

/**
 * @author Heelix
 */
public class GameServerLaunchArgumentsParser {

    private static final String CONFIG_PATH_KEY = "-DgameConfigPath";
    private static final String DEFAULT_CONFIG_PATH = "config";

    private GameServerLaunchArgumentsParser()
    {
    }

    public static GameServerLaunchArgs parse(String[] args)
    {
        String baseGameConfigPath = Arrays
                .stream(args)
                .filter(argument -> argument.startsWith(CONFIG_PATH_KEY))
                .findFirst()
                .orElse(DEFAULT_CONFIG_PATH);

        return new GameServerLaunchArgs(baseGameConfigPath);
    }
}
